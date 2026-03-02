import Foundation
import AppKit

/// Handles downloading, mounting, and installing a new app version from a GitHub DMG release.
@MainActor
final class AppUpdater: NSObject, URLSessionDownloadDelegate {

    static let shared = AppUpdater()

    enum State {
        case idle
        case downloading(Double)   // 0.0 – 1.0
        case installing
        case failed(String)
    }

    var state: State = .idle
    var onStateChange: (() -> Void)?

    private var downloadTask: URLSessionDownloadTask?

    private override init() { super.init() }

    func install(release: GitHubRelease) {
        guard let dmgURL = release.dmgDownloadURL else {
            state = .failed("No DMG asset found in this release.")
            onStateChange?()
            return
        }

        state = .downloading(0)
        onStateChange?()

        let session = URLSession(configuration: .default, delegate: self, delegateQueue: .main)
        downloadTask = session.downloadTask(with: dmgURL)
        downloadTask?.resume()
    }

    func cancel() {
        downloadTask?.cancel()
        downloadTask = nil
        state = .idle
        onStateChange?()
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
            self.onStateChange?()
        }
    }

    nonisolated func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                                 didFinishDownloadingTo location: URL) {
        // Move to a stable temp path before async work
        let dest = FileManager.default.temporaryDirectory
            .appendingPathComponent("r2vault_update.dmg")
        try? FileManager.default.removeItem(at: dest)
        do {
            try FileManager.default.moveItem(at: location, to: dest)
        } catch {
            Task { @MainActor in
                self.state = .failed("Failed to save DMG: \(error.localizedDescription)")
                self.onStateChange?()
            }
            return
        }

        Task { @MainActor in
            await self.mountAndInstall(dmg: dest)
        }
    }

    nonisolated func urlSession(_ session: URLSession, task: URLSessionTask,
                                 didCompleteWithError error: Error?) {
        guard let error else { return }
        // Cancellations are intentional — don't show error
        if (error as NSError).code == NSURLErrorCancelled { return }
        Task { @MainActor in
            self.state = .failed(error.localizedDescription)
            self.onStateChange?()
        }
    }

    // MARK: - Mount & Install

    private func mountAndInstall(dmg: URL) async {
        state = .installing
        onStateChange?()

        do {
            // 1. Mount the DMG
            let mountPoint = try await mountDMG(at: dmg)

            // 2. Find the .app inside the mounted volume
            let contents = try FileManager.default.contentsOfDirectory(atPath: mountPoint)
            guard let appName = contents.first(where: { $0.hasSuffix(".app") }) else {
                throw UpdateError.appNotFoundInDMG
            }
            let sourceApp = URL(fileURLWithPath: mountPoint).appendingPathComponent(appName)

            // 3. Determine destination — replace the currently running app
            guard let runningAppPath = Bundle.main.bundleURL.path.removingPercentEncoding else {
                throw UpdateError.couldNotDetermineAppPath
            }
            let destApp = URL(fileURLWithPath: runningAppPath)

            // 4. Replace with ditto (preserves permissions, symlinks, etc.)
            try await runShell("/bin/rm", args: ["-rf", destApp.path])
            try await runShell("/usr/bin/ditto", args: [sourceApp.path, destApp.path])

            // 5. Unmount
            _ = try? await runShell("/usr/bin/hdiutil", args: ["detach", mountPoint, "-quiet"])

            // 6. Relaunch
            let newAppPath = destApp.path
            let pid = ProcessInfo.processInfo.processIdentifier
            // Use a short shell script to wait for this process to exit then reopen
            let script = "while kill -0 \(pid) 2>/dev/null; do sleep 0.2; done; open \"\(newAppPath)\""
            Process.launchedProcess(launchPath: "/bin/sh", arguments: ["-c", script])
            NSApplication.shared.terminate(nil)

        } catch {
            state = .failed(error.localizedDescription)
            onStateChange?()
        }
    }

    private func mountDMG(at url: URL) async throws -> String {
        let result = try await runShellOutput("/usr/bin/hdiutil", args: [
            "attach", url.path,
            "-nobrowse", "-noautoopen",
            "-plist", "-quiet"
        ])

        // Parse the plist output to find the mount point
        guard let data = result.data(using: .utf8),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let entities = plist["system-entities"] as? [[String: Any]],
              let mountPoint = entities.compactMap({ $0["mount-point"] as? String }).first
        else {
            throw UpdateError.couldNotMountDMG
        }
        return mountPoint
    }

    @discardableResult
    private func runShell(_ path: String, args: [String]) async throws -> Int32 {
        try await withCheckedThrowingContinuation { continuation in
            let p = Process()
            p.executableURL = URL(fileURLWithPath: path)
            p.arguments = args
            p.terminationHandler = { process in
                if process.terminationStatus == 0 {
                    continuation.resume(returning: process.terminationStatus)
                } else {
                    continuation.resume(throwing: UpdateError.shellFailed(path, process.terminationStatus))
                }
            }
            do { try p.run() } catch { continuation.resume(throwing: error) }
        }
    }

    private func runShellOutput(_ path: String, args: [String]) async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            let p = Process()
            let pipe = Pipe()
            p.executableURL = URL(fileURLWithPath: path)
            p.arguments = args
            p.standardOutput = pipe
            p.terminationHandler = { _ in
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                continuation.resume(returning: String(data: data, encoding: .utf8) ?? "")
            }
            do { try p.run() } catch { continuation.resume(throwing: error) }
        }
    }
}

enum UpdateError: LocalizedError {
    case appNotFoundInDMG
    case couldNotDetermineAppPath
    case couldNotMountDMG
    case shellFailed(String, Int32)

    var errorDescription: String? {
        switch self {
        case .appNotFoundInDMG:        return "Could not find .app inside the DMG."
        case .couldNotDetermineAppPath: return "Could not determine the running app path."
        case .couldNotMountDMG:        return "Could not mount the DMG."
        case .shellFailed(let cmd, let code): return "\(cmd) exited with code \(code)."
        }
    }
}
