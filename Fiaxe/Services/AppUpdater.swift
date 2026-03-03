import Foundation
import AppKit
import Darwin
import Observation

/// Handles downloading, mounting, and installing a new app version from a GitHub DMG release.
@MainActor
@Observable
final class AppUpdater: NSObject, URLSessionDownloadDelegate {

    static let shared = AppUpdater()

    enum State {
        case idle
        case downloading(Double)   // 0.0 – 1.0
        case downloaded(URL)
        case installing
        case failed(String)

        var isFailed: Bool {
            if case .failed = self { return true }
            return false
        }

        var isDownloaded: Bool {
            if case .downloaded = self { return true }
            return false
        }
    }

    var state: State = .idle

    private var downloadTask: URLSessionDownloadTask?
    private let cachedDMGURL: URL = {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
        return base.appendingPathComponent("R2Vault", isDirectory: true)
            .appendingPathComponent("R2VaultUpdate.dmg")
    }()
    private let logFileURL = FileManager.default
        .urls(for: .libraryDirectory, in: .userDomainMask)
        .first!
        .appendingPathComponent("Logs")
        .appendingPathComponent("R2VaultUpdater.log")
    var updateBlockReason: String? {
        guard let bundlePath = Bundle.main.bundleURL.path.removingPercentEncoding else {
            return "Could not determine the running app path."
        }
        if isRunningFromXcodeBuild(path: bundlePath) {
            return "You're running from an Xcode build. Move R2 Vault into /Applications (or ~/Applications) to install updates."
        }
        let bundleURL = URL(fileURLWithPath: bundlePath)
        if !FileManager.default.isWritableFile(atPath: bundleURL.deletingLastPathComponent().path) {
            return "The app isn't in a writable location. Move it into /Applications (or ~/Applications) to install updates."
        }
        return nil
    }

    var canSelfUpdate: Bool { updateBlockReason == nil }

    private override init() { super.init() }

    func install(release: GitHubRelease) {
        download(release: release)
    }

    func download(release: GitHubRelease) {
        guard let dmgURL = release.dmgDownloadURL else {
            state = .failed("No DMG asset found in this release.")
            return
        }

        state = .downloading(0)

        let session = URLSession(configuration: .default, delegate: self, delegateQueue: nil)
        downloadTask = session.downloadTask(with: dmgURL)
        downloadTask?.resume()
    }

    func cancel() {
        downloadTask?.cancel()
        downloadTask = nil
        state = .idle
    }

    func installDownloaded() {
        guard case .downloaded(let dmgURL) = state else { return }
        Task { @MainActor in
            await self.mountAndInstall(dmg: dmgURL)
        }
    }

    // MARK: - URLSessionDownloadDelegate

    nonisolated func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                                 didWriteData bytesWritten: Int64,
                                 totalBytesWritten: Int64,
                                 totalBytesExpectedToWrite: Int64) {
        let progress = totalBytesExpectedToWrite > 0
            ? Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)
            : 0
        Task { @MainActor in
            self.state = .downloading(progress)
        }
    }

    nonisolated func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                                 didFinishDownloadingTo location: URL) {
        // Move to a stable cache path so it can be installed later
        let dest = cachedDMGURL
        do {
            try FileManager.default.createDirectory(
                at: dest.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
        } catch {
            Task { @MainActor in
                self.state = .failed("Failed to prepare update cache: \(error.localizedDescription)")
            }
            return
        }
        try? FileManager.default.removeItem(at: dest)
        do {
            try FileManager.default.moveItem(at: location, to: dest)
        } catch {
            Task { @MainActor in
                self.state = .failed("Failed to save DMG: \(error.localizedDescription)")
            }
            return
        }

        Task { @MainActor in
            self.state = .downloaded(dest)
        }
    }

    nonisolated func urlSession(_ session: URLSession, task: URLSessionTask,
                                 didCompleteWithError error: Error?) {
        guard let error else { return }
        // Cancellations are intentional — don't show error
        if (error as NSError).code == NSURLErrorCancelled { return }
        Task { @MainActor in
            self.state = .failed(error.localizedDescription)
        }
    }

    // MARK: - Mount & Install

    private func mountAndInstall(dmg: URL) async {
        state = .installing

        do {
            self.log("Installing update from DMG: \(dmg.path)")
            try await self.withTimeout(180, operation: { [self] in
                // 1. Mount the DMG
                let mountPoint = try await self.mountDMG(at: dmg)
                self.log("Mounted DMG at: \(mountPoint)")
                defer {
                    Task.detached {
                        _ = try? await self.runProcess("/usr/bin/hdiutil", args: ["detach", mountPoint, "-quiet"], timeout: 30)
                        await self.log("Detached DMG: \(mountPoint)")
                    }
                }

                // 2. Find the .app inside the mounted volume
                let contents = try FileManager.default.contentsOfDirectory(atPath: mountPoint)
                guard let appName = contents.first(where: { $0.hasSuffix(".app") }) else {
                    throw UpdateError.appNotFoundInDMG
                }
                let sourceApp = URL(fileURLWithPath: mountPoint).appendingPathComponent(appName)
                self.log("Found app in DMG: \(sourceApp.path)")

                // 3. Determine destination — prefer the current app location if writable
                guard let runningAppPath = Bundle.main.bundleURL.path.removingPercentEncoding else {
                    throw UpdateError.couldNotDetermineAppPath
                }
                let runningAppURL = URL(fileURLWithPath: runningAppPath)
                let appNameForInstall = runningAppURL.lastPathComponent
                let destApp = try self.determineInstallDestination(appName: appNameForInstall, preferred: runningAppURL)
                self.log("Install destination: \(destApp.path)")

                // 4. Copy new app to a temp location (avoid modifying the running app)
                let tempApp = FileManager.default.temporaryDirectory.appendingPathComponent("r2vault_update.app")
                try? FileManager.default.removeItem(at: tempApp)
                _ = try await self.runProcess("/usr/bin/ditto", args: [sourceApp.path, tempApp.path], timeout: 120)
                self.log("Copied to temp: \(tempApp.path)")

                // 5. Unmount early (temp copy is done)
                _ = try? await self.runProcess("/usr/bin/hdiutil", args: ["detach", mountPoint, "-quiet"], timeout: 30)

                // 6. Replace after this app exits, then relaunch
                let pid = ProcessInfo.processInfo.processIdentifier
                let escapedTemp = self.shellEscape(tempApp.path)
                let escapedDest = self.shellEscape(destApp.path)
                let escapedDMG = self.shellEscape(dmg.path)
                let script = """
                while kill -0 \(pid) 2>/dev/null; do sleep 0.2; done
                /bin/rm -rf \(escapedDest)
                /usr/bin/ditto \(escapedTemp) \(escapedDest)
                /usr/bin/xattr -dr com.apple.quarantine \(escapedDest) 2>/dev/null
                /bin/rm -rf \(escapedTemp)
                /bin/rm -f \(escapedDMG)
                open \(escapedDest)
                """
                self.log("Launching post-quit install script.")
                Process.launchedProcess(launchPath: "/bin/sh", arguments: ["-c", script])
                NSApplication.shared.terminate(nil)
                DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                    self.log("Force quitting to allow install.")
                    Darwin.exit(0)
                }
            })

        } catch {
            self.log("Install failed: \(error.localizedDescription)")
            state = .failed(error.localizedDescription)
        }
    }

    private func mountDMG(at url: URL) async throws -> String {
        let result = try await runProcess("/usr/bin/hdiutil", args: [
            "attach", url.path,
            "-nobrowse", "-noautoopen",
            "-plist"
        ], timeout: 60)

        // Parse the plist output to find the mount point
        guard let data = result.stdout.data(using: .utf8),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let entities = plist["system-entities"] as? [[String: Any]],
              let mountPoint = entities.compactMap({ $0["mount-point"] as? String }).first
        else {
            throw UpdateError.couldNotMountDMG
        }
        return mountPoint
    }

    @discardableResult
    private nonisolated func runProcess(_ path: String, args: [String], timeout: TimeInterval) async throws -> ProcessResult {
        try await Task.detached {
            let p = Process()
            let stdoutPipe = Pipe()
            let stderrPipe = Pipe()
            p.executableURL = URL(fileURLWithPath: path)
            p.arguments = args
            p.standardOutput = stdoutPipe
            p.standardError = stderrPipe
            try p.run()

            let didExit = try await withThrowingTaskGroup(of: Bool.self) { group in
                group.addTask {
                    p.waitUntilExit()
                    return true
                }
                group.addTask {
                    try await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                    return false
                }
                let first = try await group.next() ?? false
                group.cancelAll()
                return first
            }

            if !didExit {
                p.terminate()
                throw UpdateError.timedOut(path, timeout)
            }

            let stdoutData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
            let stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
            let stdout = String(data: stdoutData, encoding: .utf8) ?? ""
            let stderr = String(data: stderrData, encoding: .utf8) ?? ""

            let status = p.terminationStatus
            if status != 0 {
                throw UpdateError.shellFailed(path, status, stderr.isEmpty ? stdout : stderr)
            }
            return ProcessResult(stdout: stdout, stderr: stderr, status: status)
        }.value
    }

    private func shellEscape(_ value: String) -> String {
        "\"\(value.replacingOccurrences(of: "\"", with: "\\\""))\""
    }

    private func determineInstallDestination(appName: String, preferred: URL) throws -> URL {
        let fileManager = FileManager.default
        var candidates: [URL] = []
        if fileManager.isWritableFile(atPath: preferred.deletingLastPathComponent().path) {
            candidates.append(preferred)
        }
        if let systemApps = fileManager.urls(for: .applicationDirectory, in: .localDomainMask).first {
            candidates.append(systemApps.appendingPathComponent(appName))
        }
        if let userApps = fileManager.urls(for: .applicationDirectory, in: .userDomainMask).first {
            candidates.append(userApps.appendingPathComponent(appName))
        }

        if let dest = candidates.first(where: { fileManager.isWritableFile(atPath: $0.deletingLastPathComponent().path) }) {
            return dest
        }
        throw UpdateError.notWritableInstallLocation
    }

    private func isRunningFromXcodeBuild(path: String) -> Bool {
        path.contains("/DerivedData/") || path.contains("/Build/Products/")
    }

    private func withTimeout<T>(_ seconds: TimeInterval, operation: @escaping () async throws -> T) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask {
                try await operation()
            }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                throw UpdateError.timedOut("install", seconds)
            }
            let result = try await group.next()!
            group.cancelAll()
            return result
        }
    }

    @MainActor
    private func log(_ message: String) {
        let timestamp = ISO8601DateFormatter().string(from: Date())
        let line = "[\(timestamp)] \(message)\n"
        if let data = line.data(using: .utf8) {
            if !FileManager.default.fileExists(atPath: logFileURL.deletingLastPathComponent().path) {
                try? FileManager.default.createDirectory(at: logFileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            }
            if FileManager.default.fileExists(atPath: logFileURL.path) {
                if let handle = try? FileHandle(forWritingTo: logFileURL) {
                    _ = try? handle.seekToEnd()
                    try? handle.write(contentsOf: data)
                    try? handle.close()
                }
            } else {
                try? data.write(to: logFileURL)
            }
        }
    }
}

private struct ProcessResult {
    let stdout: String
    let stderr: String
    let status: Int32
}

enum UpdateError: LocalizedError {
    case appNotFoundInDMG
    case couldNotDetermineAppPath
    case couldNotMountDMG
    case shellFailed(String, Int32, String)
    case timedOut(String, TimeInterval)
    case notWritableInstallLocation

    var errorDescription: String? {
        switch self {
        case .appNotFoundInDMG:        return "Could not find .app inside the DMG."
        case .couldNotDetermineAppPath: return "Could not determine the running app path."
        case .couldNotMountDMG:        return "Could not mount the DMG."
        case .shellFailed(let cmd, let code, let details):
            let trimmed = details.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty
                ? "\(cmd) exited with code \(code)."
                : "\(cmd) exited with code \(code): \(trimmed)"
        case .timedOut(let cmd, let seconds):
            return "\(cmd) timed out after \(Int(seconds)) seconds."
        case .notWritableInstallLocation:
            return "The app can't write to the install location. Move R2 Vault into /Applications (or ~/Applications) and try again."
        }
    }
}
