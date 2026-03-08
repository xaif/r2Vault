#if os(iOS)
import Foundation
import UIKit

@MainActor
final class BackgroundDownloadService: NSObject {
    static let shared = BackgroundDownloadService()

    private static let sessionIdentifier = "fiaxe.r2vault.background-downloads"

    private struct PendingDownload {
        let destinationURL: URL
        let onSuccess: @MainActor (URL) -> Void
        let onFailure: @MainActor (Error) -> Void
    }

    private var pendingDownloads: [Int: PendingDownload] = [:]
    private var backgroundCompletionHandler: (() -> Void)?

    private lazy var session: URLSession = {
        let configuration = URLSessionConfiguration.background(withIdentifier: Self.sessionIdentifier)
        configuration.sessionSendsLaunchEvents = true
        configuration.isDiscretionary = false
        configuration.waitsForConnectivity = true
        return URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
    }()

    func download(
        from remoteURL: URL,
        to destinationURL: URL,
        onSuccess: @escaping @MainActor (URL) -> Void,
        onFailure: @escaping @MainActor (Error) -> Void
    ) {
        let task = session.downloadTask(with: remoteURL)
        pendingDownloads[task.taskIdentifier] = PendingDownload(
            destinationURL: destinationURL,
            onSuccess: onSuccess,
            onFailure: onFailure
        )
        task.resume()
    }

    func handleBackgroundEvents(completionHandler: @escaping () -> Void) {
        backgroundCompletionHandler = completionHandler
    }
}

extension BackgroundDownloadService: URLSessionDownloadDelegate, URLSessionTaskDelegate {
    nonisolated func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didFinishDownloadingTo location: URL
    ) {
        Task { @MainActor in
            guard let pending = pendingDownloads[downloadTask.taskIdentifier] else { return }

            do {
                try FileManager.default.moveItem(at: location, to: pending.destinationURL)
                pendingDownloads[downloadTask.taskIdentifier] = nil
                pending.onSuccess(pending.destinationURL)
            } catch {
                pendingDownloads[downloadTask.taskIdentifier] = nil
                pending.onFailure(error)
            }
        }
    }

    nonisolated func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let error else { return }

        Task { @MainActor in
            guard let pending = pendingDownloads[task.taskIdentifier] else { return }
            pendingDownloads[task.taskIdentifier] = nil
            pending.onFailure(error)
        }
    }

    nonisolated func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        Task { @MainActor in
            let completionHandler = backgroundCompletionHandler
            backgroundCompletionHandler = nil
            completionHandler?()
        }
    }
}
#endif
