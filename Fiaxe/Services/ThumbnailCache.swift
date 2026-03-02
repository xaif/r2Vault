import AppKit
import AVFoundation

/// Shared in-memory + disk-backed thumbnail cache for R2 objects.
/// Thumbnails are fetched asynchronously from the public URL and cached by key.
actor ThumbnailCache {

    static let shared = ThumbnailCache()

    private let memoryCache = NSCache<NSString, NSImage>()

    // Disk cache directory
    private let diskCacheURL: URL = {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
        let dir = caches.appendingPathComponent("R2VaultThumbnails", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    // Tracks in-flight requests so we don't double-fetch
    private var inFlight: [String: Task<NSImage?, Never>] = [:]

    private init() {
        memoryCache.countLimit = 500
        memoryCache.totalCostLimit = 100 * 1024 * 1024 // 100 MB
    }

    /// Returns a cached thumbnail or fetches it using a presigned URL.
    /// `key` is the R2 object key used as cache identifier.
    func thumbnail(for key: String, credentials: R2Credentials) async -> NSImage? {
        let cacheKey = key as NSString

        // 1. Memory cache hit
        if let img = memoryCache.object(forKey: cacheKey) { return img }

        // 2. Disk cache hit
        if let img = loadFromDisk(key: key) {
            memoryCache.setObject(img, forKey: cacheKey)
            return img
        }

        // 3. Coalesce in-flight requests
        if let task = inFlight[key] { return await task.value }

        // Generate presigned URL — works whether or not a custom domain is set
        guard let url = AWSV4Signer.presignedURL(for: key, credentials: credentials) else {
            return nil
        }

        let task = Task<NSImage?, Never> {
            let img = await fetchThumbnail(url: url, key: key)
            if let img {
                memoryCache.setObject(img, forKey: cacheKey)
                saveToDisk(img, key: key)
            }
            return img
        }
        inFlight[key] = task
        let result = await task.value
        inFlight.removeValue(forKey: key)
        return result
    }

    /// Clears the entire in-memory cache.
    func clearMemory() {
        memoryCache.removeAllObjects()
    }

    // MARK: - Fetch

    private func fetchThumbnail(url: URL, key: String) async -> NSImage? {
        let ext = (key as NSString).pathExtension.lowercased()
        if isVideo(ext) {
            return await videoThumbnail(url: url)
        } else {
            return await imageThumbnail(url: url)
        }
    }

    private func imageThumbnail(url: URL) async -> NSImage? {
        guard let (data, _) = try? await URLSession.shared.data(from: url),
              let src = NSImage(data: data) else { return nil }
        return resized(src, to: CGSize(width: 120, height: 120))
    }

    private func videoThumbnail(url: URL) async -> NSImage? {
        let asset = AVURLAsset(url: url)
        let gen = AVAssetImageGenerator(asset: asset)
        gen.appliesPreferredTrackTransform = true
        gen.maximumSize = CGSize(width: 120, height: 120)
        guard let cgImage = try? await gen.image(at: .zero).image else { return nil }
        return NSImage(cgImage: cgImage, size: NSSize(width: 120, height: 120))
    }

    // MARK: - Resize

    private func resized(_ image: NSImage, to size: CGSize) -> NSImage {
        let original = image.size
        guard original.width > 0, original.height > 0 else { return image }

        let scale = min(size.width / original.width, size.height / original.height)
        let newSize = CGSize(width: original.width * scale, height: original.height * scale)

        let result = NSImage(size: newSize)
        result.lockFocus()
        image.draw(in: CGRect(origin: .zero, size: newSize),
                   from: CGRect(origin: .zero, size: original),
                   operation: .copy, fraction: 1)
        result.unlockFocus()
        return result
    }

    // MARK: - Disk I/O

    private func diskURL(for key: String) -> URL {
        // Use a safe filename derived from the key
        let safe = key
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: ":", with: "_")
        return diskCacheURL.appendingPathComponent(safe + ".png")
    }

    private func loadFromDisk(key: String) -> NSImage? {
        let url = diskURL(for: key)
        guard FileManager.default.fileExists(atPath: url.path),
              let img = NSImage(contentsOf: url) else { return nil }
        return img
    }

    private func saveToDisk(_ image: NSImage, key: String) {
        guard let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:]) else { return }
        try? png.write(to: diskURL(for: key))
    }

    // MARK: - Helpers

    private func isVideo(_ ext: String) -> Bool {
        ["mp4", "mov", "avi", "mkv", "webm", "m4v"].contains(ext)
    }
}
