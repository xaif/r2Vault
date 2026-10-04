import FileProvider
import SQLite3

/// What the extension last told the system about one bucket entry.
struct ItemRecord: Sendable, Equatable {
    var id: String
    /// Full object key. Folders end in "/", the root is "".
    var key: String
    var parentID: String
    var name: String
    var isFolder: Bool
    var size: Int64
    var etag: String
    var modified: Date?
    var seq: Int64
    /// The user chose "Keep Downloaded" in Finder for this item.
    var keepDownloaded = false
}

/// A child entry seen in a server listing.
struct ServerEntry: Sendable {
    let key: String
    let name: String
    let isFolder: Bool
    let size: Int64
    let etag: String
    let modified: Date?
}

/// SQLite store mapping stable File Provider identifiers to R2 keys.
///
/// The system requires an item's identifier to survive renames and moves, but S3 keys change
/// whenever an object moves. New items are identified by their key; the identifier then stays
/// with the item while its key changes underneath.
///
/// Every change bumps a global sequence number. The working set's sync anchor is that number,
/// so "changes since anchor N" is a simple query.
final class ItemDatabase: @unchecked Sendable {
    /// Bump when item metadata changes shape so every item is re-reported once.
    /// 2: eager namespace policy for folders (macOS 27). 3: evictable downloads.
    /// 4: content policy and Keep Downloaded state for Finder's actions.
    static let itemMetadataVersion = "4"
    static let rootID = NSFileProviderItemIdentifier.rootContainer.rawValue
    static let trashID = NSFileProviderItemIdentifier.trashContainer.rawValue

    private var db: OpaquePointer?
    private let lock = NSRecursiveLock()

    /// Random per-database value embedded in sync anchors, so anchors from a deleted database are rejected.
    private(set) var epoch = ""

    init(url: URL, rootID: String, trashID: String, trashKey: String) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard sqlite3_open_v2(url.path, &db, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK else {
            throw CocoaError(.fileReadCorruptFile)
        }
        try exec("PRAGMA journal_mode=WAL")
        try exec("""
            CREATE TABLE IF NOT EXISTS items (
                id TEXT PRIMARY KEY,
                key TEXT NOT NULL UNIQUE,
                parent_id TEXT NOT NULL,
                name TEXT NOT NULL,
                is_folder INTEGER NOT NULL,
                size INTEGER NOT NULL DEFAULT 0,
                etag TEXT NOT NULL DEFAULT '',
                modified REAL,
                seq INTEGER NOT NULL,
                keep_downloaded INTEGER NOT NULL DEFAULT 0
            );
            CREATE INDEX IF NOT EXISTS items_parent ON items(parent_id);
            CREATE INDEX IF NOT EXISTS items_seq ON items(seq);
            CREATE TABLE IF NOT EXISTS tombstones (id TEXT PRIMARY KEY, seq INTEGER NOT NULL);
            CREATE INDEX IF NOT EXISTS tombstones_seq ON tombstones(seq);
            CREATE TABLE IF NOT EXISTS listed (folder_id TEXT PRIMARY KEY, refreshed_at REAL NOT NULL);
            CREATE TABLE IF NOT EXISTS meta (k TEXT PRIMARY KEY, v TEXT NOT NULL);
            CREATE TABLE IF NOT EXISTS uploads (key TEXT PRIMARY KEY, upload_id TEXT NOT NULL, size INTEGER NOT NULL,
                                                part_size INTEGER NOT NULL, started REAL NOT NULL);
            CREATE TABLE IF NOT EXISTS upload_parts (upload_id TEXT NOT NULL, number INTEGER NOT NULL, etag TEXT NOT NULL,
                                                     md5 TEXT NOT NULL, PRIMARY KEY (upload_id, number));
            """)
        // Databases created before Keep Downloaded lack the column.
        var hasKeepDownloaded = false
        _ = queryRaw("SELECT 1 FROM pragma_table_info('items') WHERE name = 'keep_downloaded'") { _ in hasKeepDownloaded = true }
        if !hasKeepDownloaded {
            try exec("ALTER TABLE items ADD COLUMN keep_downloaded INTEGER NOT NULL DEFAULT 0")
        }

        if let existing = meta("epoch") {
            epoch = existing
        } else {
            epoch = UUID().uuidString
            setMeta("epoch", epoch)
            setMeta("seq", "0")
        }
        // Re-report every item once whenever item metadata changes shape (e.g. new
        // capabilities), so the system picks it up for items it already knows.
        if meta("itemMetadataVersion") != Self.itemMetadataVersion {
            try exec("UPDATE items SET seq = ? WHERE id NOT IN (?, ?)", nextSeq(), rootID, trashID)
            setMeta("itemMetadataVersion", Self.itemMetadataVersion)
        }
                // Containers are not reported as items, so they never need a seq bump.
        try exec("INSERT OR IGNORE INTO items (id, key, parent_id, name, is_folder, seq) VALUES (?, '', ?, '', 1, 0)", rootID, rootID)
        try exec("INSERT OR IGNORE INTO items (id, key, parent_id, name, is_folder, seq) VALUES (?, ?, ?, '', 1, 0)", trashID, trashKey, trashID)
    }

    deinit {
        sqlite3_close_v2(db)
    }

    // MARK: - Lookups

    func record(id: String) -> ItemRecord? {
        lock.withLock { query("SELECT \(Self.columns) FROM items WHERE id = ?", id).first }
    }

    func record(key: String) -> ItemRecord? {
        lock.withLock { query("SELECT \(Self.columns) FROM items WHERE key = ?", key).first }
    }

    func children(of parentID: String) -> [ItemRecord] {
        lock.withLock { query("SELECT \(Self.columns) FROM items WHERE parent_id = ? AND id != ?", parentID, parentID) }
    }

    /// Records under a folder key at any depth (not including the folder itself).
    func descendants(ofKey folderKey: String) -> [ItemRecord] {
        lock.withLock {
            query("SELECT \(Self.columns) FROM items WHERE substr(key, 1, ?) = ? AND key != ?",
                  Self.length(folderKey), folderKey, folderKey)
        }
    }

    /// Every reported item, for the working set's full enumeration.
    func allItems(after rowID: Int64, limit: Int) -> (items: [ItemRecord], lastRowID: Int64) {
        lock.withLock {
            var lastRowID = rowID
            var items: [ItemRecord] = []
            let rows = query("SELECT \(Self.columns), rowid FROM items WHERE rowid > ? AND id NOT IN (?, ?) ORDER BY rowid LIMIT ?",
                             rowID, Self.rootID, Self.trashID, Int64(limit)) { statement in
                lastRowID = sqlite3_column_int64(statement, Self.columnCount)
            }
            items = rows
            return (items, lastRowID)
        }
    }

    // MARK: - Change tracking

    var currentSeq: Int64 {
        lock.withLock { Int64(meta("seq") ?? "0") ?? 0 }
    }

    /// Everything that changed after `seq`.
    func changes(since seq: Int64) -> (updated: [ItemRecord], deleted: [String], latest: Int64) {
        lock.withLock {
            let updated = query("SELECT \(Self.columns) FROM items WHERE seq > ? AND id NOT IN (?, ?) ORDER BY seq",
                                seq, Self.rootID, Self.trashID)
            var deleted: [String] = []
            _ = queryRaw("SELECT id FROM tombstones WHERE seq > ? ORDER BY seq", seq) { statement in
                deleted.append(Self.string(statement, 0))
            }
            return (updated, deleted, Int64(meta("seq") ?? "0") ?? 0)
        }
    }

    private func nextSeq() -> Int64 {
        let next = (Int64(meta("seq") ?? "0") ?? 0) + 1
        setMeta("seq", String(next))
        return next
    }

    // MARK: - Mutations

    /// Sets Keep Downloaded on the given items. Returns the records that changed.
    func setKeepDownloaded(_ keep: Bool, ids: [String]) -> [ItemRecord] {
        lock.withLock {
            transaction {
                ids.compactMap { id in
                    guard var record = query("SELECT \(Self.columns) FROM items WHERE id = ?", id).first,
                          record.keepDownloaded != keep else { return nil }
                    record.keepDownloaded = keep
                    record.seq = nextSeq()
                    write(record)
                    return record
                }
            }
        }
    }

    /// Picks an identifier for a newly seen key: the key itself when it is free.
    private func newIdentifier(for key: String) -> String {
        if query("SELECT \(Self.columns) FROM items WHERE id = ?", key).isEmpty {
            return key
        }
        return "id:" + UUID().uuidString
    }

    /// Inserts a new item, or overwrites the item already at `key`. Returns the stored record.
    @discardableResult
    func upsert(key: String, parentID: String, name: String, isFolder: Bool,
                size: Int64, etag: String, modified: Date?) -> ItemRecord {
        lock.withLock {
            transaction {
                upsertLocked(ServerEntry(key: key, name: name, isFolder: isFolder, size: size, etag: etag, modified: modified),
                             parentID: parentID, forceBump: true)
            }
        }
    }

    @discardableResult
    private func upsertLocked(_ entry: ServerEntry, parentID: String, forceBump: Bool) -> ItemRecord {
        if var existing = query("SELECT \(Self.columns) FROM items WHERE key = ?", entry.key).first {
            let contentChanged = existing.isFolder != entry.isFolder
                || existing.size != entry.size
                || (!entry.etag.isEmpty && existing.etag != entry.etag)
            // R2 has no date for folder prefixes; without one Finder shows 1 Jan 1970.
            let missingFolderDate = existing.isFolder && existing.modified == nil && entry.modified == nil
            let changed = contentChanged || missingFolderDate
                || existing.parentID != parentID || !Self.sameBytes(existing.name, entry.name)
            guard changed || forceBump else { return existing }

            existing.parentID = parentID
            existing.name = entry.name
            existing.isFolder = entry.isFolder
            existing.size = entry.size
            if !entry.etag.isEmpty { existing.etag = entry.etag }
            // Listings only carry the upload time, so keep a locally supplied date
            // unless the content itself changed.
            if forceBump || contentChanged || existing.modified == nil {
                existing.modified = entry.modified ?? existing.modified
            }
            if missingFolderDate {
                existing.modified = Date()
            }
            existing.seq = nextSeq()
            write(existing)
            return existing
        }

        let record = ItemRecord(
            id: newIdentifier(for: entry.key),
            key: entry.key,
            parentID: parentID,
            name: entry.name,
            isFolder: entry.isFolder,
            size: entry.size,
            etag: entry.etag,
            modified: entry.modified ?? (entry.isFolder ? Date() : nil),
            seq: nextSeq()
        )
        write(record)
        return record
    }

    /// Stores `record` as-is with a fresh seq.
    @discardableResult
    func update(_ record: ItemRecord) -> ItemRecord {
        lock.withLock {
            transaction {
                var record = record
                record.seq = nextSeq()
                write(record)
                return record
            }
        }
    }

    private func write(_ record: ItemRecord) {
        try? exec("""
            INSERT INTO items (id, key, parent_id, name, is_folder, size, etag, modified, seq, keep_downloaded)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(id) DO UPDATE SET key = excluded.key, parent_id = excluded.parent_id, name = excluded.name,
                is_folder = excluded.is_folder, size = excluded.size, etag = excluded.etag,
                modified = excluded.modified, seq = excluded.seq, keep_downloaded = excluded.keep_downloaded
            """,
            record.id, record.key, record.parentID, record.name, record.isFolder ? Int64(1) : Int64(0),
            record.size, record.etag, record.modified.map { $0.timeIntervalSince1970 } as Any, record.seq,
            record.keepDownloaded ? Int64(1) : Int64(0))
        try? exec("DELETE FROM tombstones WHERE id = ?", record.id)
    }

    /// Moves an item to a new key. For folders, every descendant's key is rewritten too;
    /// descendants keep their identifiers and parents.
    @discardableResult
    func move(id: String, toKey newKey: String, parentID: String, name: String) -> ItemRecord? {
        lock.withLock {
            transaction {
                guard var record = query("SELECT \(Self.columns) FROM items WHERE id = ?", id).first else { return nil }
                let oldKey = record.key

                // Drop anything a refresh may have recorded at the destination in the meantime.
                let squatters = record.isFolder
                    ? query("SELECT \(Self.columns) FROM items WHERE substr(key, 1, ?) = ?", Self.length(newKey), newKey)
                    : query("SELECT \(Self.columns) FROM items WHERE key = ?", newKey)
                for squatter in squatters where squatter.id != id && !squatter.key.utf8.starts(with: oldKey.utf8) {
                    removeLocked(squatter)
                }

                if record.isFolder {
                    try? exec("UPDATE items SET key = ? || substr(key, ?) WHERE substr(key, 1, ?) = ? AND key != ?",
                              newKey, Self.length(oldKey) + 1, Self.length(oldKey), oldKey, oldKey)
                }
                record.key = newKey
                record.parentID = parentID
                record.name = name
                record.seq = nextSeq()
                write(record)
                try? exec("UPDATE listed SET refreshed_at = 0 WHERE folder_id = ?", id)
                return record
            }
        }
    }

    /// Removes an item and, for folders, everything under it. Tombstones are written for all
    /// removed descendants so the working set reports them.
    func remove(id: String) {
        lock.withLock {
            transaction {
                if let record = query("SELECT \(Self.columns) FROM items WHERE id = ?", id).first {
                    removeLocked(record)
                }
            }
        }
    }

    private func removeLocked(_ record: ItemRecord) {
        var victims = [record]
        if record.isFolder {
            victims += query("SELECT \(Self.columns) FROM items WHERE substr(key, 1, ?) = ? AND key != ?",
                             Self.length(record.key), record.key, record.key)
        }
        for victim in victims where victim.id != Self.rootID && victim.id != Self.trashID {
            try? exec("DELETE FROM items WHERE id = ?", victim.id)
            try? exec("DELETE FROM listed WHERE folder_id = ?", victim.id)
            try? exec("INSERT OR REPLACE INTO tombstones (id, seq) VALUES (?, ?)", victim.id, nextSeq())
        }
    }

    /// Applies a complete server listing of one folder, taken at `startedAt` for `listedKey`.
    /// Children missing from the listing are removed; `isBusy` keys (touched by local operations
    /// since the listing started) are left alone.
    ///
    /// The listing is discarded if the folder was deleted or moved while it was being fetched,
    /// or if a newer listing of the folder has already been applied.
    /// Returns the folder's children and whether anything changed, or nil if the folder is gone
    /// or now lives at a different key.
    func reconcile(folderID: String, listedKey: String, startedAt: Date, entries: [ServerEntry],
                   isBusy: (String) -> Bool) -> (children: [ItemRecord], changed: Bool)? {
        lock.withLock {
            transaction {
                let children = { self.query("SELECT \(Self.columns) FROM items WHERE parent_id = ? AND id != ?", folderID, folderID) }
                guard let folder = query("SELECT \(Self.columns) FROM items WHERE id = ?", folderID).first,
                      Self.sameBytes(folder.key, listedKey) else {
                    return nil
                }
                var lastApplied: Double?
                _ = queryRaw("SELECT refreshed_at FROM listed WHERE folder_id = ?", folderID) {
                    lastApplied = sqlite3_column_double($0, 0)
                }
                if let lastApplied, lastApplied > startedAt.timeIntervalSince1970 {
                    return (children(), false)
                }

                let before = currentSeqLocked
                let existing = children()
                // Keys are compared as bytes: Swift treats NFC and NFD spellings as equal, S3 doesn't.
                var seen = Set<[UInt8]>()
                for entry in entries where !isBusy(entry.key) {
                    seen.insert(Array(entry.key.utf8))
                    upsertLocked(entry, parentID: folderID, forceBump: false)
                }
                for record in existing where !seen.contains(Array(record.key.utf8)) && !isBusy(record.key) {
                    removeLocked(record)
                }
                try? exec("INSERT OR REPLACE INTO listed (folder_id, refreshed_at) VALUES (?, ?)",
                          folderID, startedAt.timeIntervalSince1970)
                return (children(), currentSeqLocked != before)
            }
        }
    }

    /// When `folderID` was last listed, or nil if the system has never listed it.
    func lastListed(folderID: String) -> Date? {
        lock.withLock {
            var date: Date?
            _ = queryRaw("SELECT refreshed_at FROM listed WHERE folder_id = ?", folderID) {
                date = Date(timeIntervalSince1970: sqlite3_column_double($0, 0))
            }
            return date
        }
    }

    static func sameBytes(_ a: String, _ b: String) -> Bool {
        a.utf8.elementsEqual(b.utf8)
    }

    private var currentSeqLocked: Int64 { Int64(meta("seq") ?? "0") ?? 0 }

    // MARK: - Refresh bookkeeping

    /// Folders the system has listed, least recently refreshed first.
    func listedFolders(refreshedBefore cutoff: Date, limit: Int) -> [ItemRecord] {
        lock.withLock {
            query("""
                SELECT \(Self.columns.split(separator: ",").map { "items." + $0.trimmingCharacters(in: .whitespaces) }.joined(separator: ", "))
                FROM listed JOIN items ON items.id = listed.folder_id
                WHERE listed.refreshed_at < ? ORDER BY listed.refreshed_at LIMIT ?
                """, cutoff.timeIntervalSince1970, Int64(limit))
        }
    }

    func dateValue(_ name: String) -> Date? {
        lock.withLock { meta(name).flatMap(Double.init).map(Date.init(timeIntervalSince1970:)) }
    }

    func setDateValue(_ name: String, _ date: Date) {
        lock.withLock { setMeta(name, String(date.timeIntervalSince1970)) }
    }

    // MARK: - Upload journal

    /// Unfinished multipart uploads started before `cutoff`, e.g. for files deleted mid-upload.
    func pendingUploads(startedBefore cutoff: Date) -> [PendingUpload] {
        lock.withLock {
            var keys: [String] = []
            _ = queryRaw("SELECT key FROM uploads WHERE started < ?", cutoff.timeIntervalSince1970) { keys.append(Self.string($0, 0)) }
            return keys.compactMap(pendingUploadLocked)
        }
    }

    private func pendingUploadLocked(key: String) -> PendingUpload? {
        var upload: PendingUpload?
        _ = queryRaw("SELECT upload_id, size, part_size FROM uploads WHERE key = ?", key) {
            upload = PendingUpload(key: key, uploadID: Self.string($0, 0), size: sqlite3_column_int64($0, 1),
                                   partSize: sqlite3_column_int64($0, 2))
        }
        guard var upload else { return nil }
        _ = queryRaw("SELECT number, etag, md5 FROM upload_parts WHERE upload_id = ?", upload.uploadID) {
            upload.parts[Int(sqlite3_column_int64($0, 0))] = UploadedPart(etag: Self.string($0, 1), md5: Self.string($0, 2))
        }
        return upload
    }

    // MARK: - SQLite plumbing

    private static let columns = "id, key, parent_id, name, is_folder, size, etag, modified, seq, keep_downloaded"
    private static let columnCount = Int32(columns.split(separator: ",").count)

    /// SQLite's substr()/length() count Unicode scalars, not Swift Characters.
    private static func length(_ string: String) -> Int64 {
        Int64(string.unicodeScalars.count)
    }
    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    private func transaction<T>(_ body: () -> T) -> T {
        try? exec("SAVEPOINT tx")
        let result = body()
        try? exec("RELEASE tx")
        return result
    }

    private func meta(_ key: String) -> String? {
        var value: String?
        _ = queryRaw("SELECT v FROM meta WHERE k = ?", key) { value = Self.string($0, 0) }
        return value
    }

    private func setMeta(_ key: String, _ value: String) {
        try? exec("INSERT OR REPLACE INTO meta (k, v) VALUES (?, ?)", key, value)
    }

    private func exec(_ sql: String, _ arguments: Any...) throws {
        if arguments.isEmpty {
            guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else { throw lastError() }
            return
        }
        let statement = try prepare(sql, arguments)
        defer { sqlite3_finalize(statement) }
        let status = sqlite3_step(statement)
        guard status == SQLITE_DONE || status == SQLITE_ROW else { throw lastError() }
    }

    private func query(_ sql: String, _ arguments: Any..., onRow: ((OpaquePointer) -> Void)? = nil) -> [ItemRecord] {
        var records: [ItemRecord] = []
        _ = queryRows(sql, arguments) { statement in
            records.append(Self.record(from: statement))
            onRow?(statement)
        }
        return records
    }

    private func queryRaw(_ sql: String, _ arguments: Any..., row: (OpaquePointer) -> Void) -> Bool {
        queryRows(sql, arguments, row: row)
    }

    private func queryRows(_ sql: String, _ arguments: [Any], row: (OpaquePointer) -> Void) -> Bool {
        guard let statement = try? prepare(sql, arguments) else { return false }
        defer { sqlite3_finalize(statement) }
        while sqlite3_step(statement) == SQLITE_ROW {
            row(statement)
        }
        return true
    }

    private func prepare(_ sql: String, _ arguments: [Any]) throws -> OpaquePointer {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw lastError()
        }
        for (index, argument) in arguments.enumerated() {
            let position = Int32(index + 1)
            switch argument {
            case let value as String:
                sqlite3_bind_text(statement, position, value, -1, Self.transient)
            case let value as Int64:
                sqlite3_bind_int64(statement, position, value)
            case let value as Double:
                sqlite3_bind_double(statement, position, value)
            case let value as Double?:
                if let value { sqlite3_bind_double(statement, position, value) } else { sqlite3_bind_null(statement, position) }
            default:
                sqlite3_bind_null(statement, position)
            }
        }
        return statement
    }

    private func lastError() -> NSError {
        let message = db.flatMap { sqlite3_errmsg($0) }.map { String(cString: $0) } ?? "unknown"
        return NSError(domain: "R2VaultFileProvider.SQLite", code: Int(sqlite3_errcode(db)),
                       userInfo: [NSLocalizedDescriptionKey: message])
    }

    private static func string(_ statement: OpaquePointer, _ column: Int32) -> String {
        sqlite3_column_text(statement, column).map { String(cString: $0) } ?? ""
    }

    private static func record(from statement: OpaquePointer) -> ItemRecord {
        ItemRecord(
            id: string(statement, 0),
            key: string(statement, 1),
            parentID: string(statement, 2),
            name: string(statement, 3),
            isFolder: sqlite3_column_int(statement, 4) != 0,
            size: sqlite3_column_int64(statement, 5),
            etag: string(statement, 6),
            modified: sqlite3_column_type(statement, 7) == SQLITE_NULL
                ? nil : Date(timeIntervalSince1970: sqlite3_column_double(statement, 7)),
            seq: sqlite3_column_int64(statement, 8),
            keepDownloaded: sqlite3_column_int(statement, 9) != 0
        )
    }
}

extension ItemDatabase: UploadJournal {
    func pendingUpload(key: String) -> PendingUpload? {
        lock.withLock { pendingUploadLocked(key: key) }
    }

    func startUpload(_ upload: PendingUpload) {
        lock.withLock {
            transaction {
                finishUploadLocked(key: upload.key)
                try? exec("INSERT INTO uploads (key, upload_id, size, part_size, started) VALUES (?, ?, ?, ?, ?)",
                          upload.key, upload.uploadID, upload.size, upload.partSize, Date().timeIntervalSince1970)
            }
        }
    }

    func recordPart(key: String, uploadID: String, number: Int, part: UploadedPart) {
        lock.withLock {
            try? exec("""
                INSERT OR REPLACE INTO upload_parts (upload_id, number, etag, md5)
                SELECT upload_id, ?, ?, ? FROM uploads WHERE key = ? AND upload_id = ?
                """, Int64(number), part.etag, part.md5, key, uploadID)
        }
    }

    func finishUpload(key: String) {
        lock.withLock { transaction { finishUploadLocked(key: key) } }
    }

    private func finishUploadLocked(key: String) {
        try? exec("DELETE FROM upload_parts WHERE upload_id IN (SELECT upload_id FROM uploads WHERE key = ?)", key)
        try? exec("DELETE FROM uploads WHERE key = ?", key)
    }
}
