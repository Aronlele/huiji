import Foundation
import CryptoKit
import AppKit

final class RuntimeDownloadDelegate: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private let update: @MainActor (Double?) -> Void
    private let lock = NSLock()
    private var continuation: CheckedContinuation<(URL, URLResponse), Error>?
    private var task: URLSessionDownloadTask?
    private var cancelled = false
    private let savedArchive = FileManager.default.temporaryDirectory.appendingPathComponent("huiji-runtime-" + UUID().uuidString + ".zip")
    init(update: @escaping @MainActor (Double?) -> Void) { self.update = update }

    func download(from url: URL) async throws -> (URL, URLResponse) {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 60
        configuration.timeoutIntervalForResource = 3600
        let session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                lock.lock()
                self.continuation = continuation
                let task = session.downloadTask(with: url)
                self.task = task
                let cancelled = self.cancelled
                lock.unlock()
                task.resume()
                if cancelled { task.cancel() }
            }
        } onCancel: {
            self.lock.lock()
            self.cancelled = true
            let task = self.task
            self.lock.unlock()
            task?.cancel()
        }
    }

    private func finish(_ result: Result<(URL, URLResponse), Error>) {
        lock.lock()
        let pending = continuation
        continuation = nil
        task = nil
        lock.unlock()
        pending?.resume(with: result)
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error { finish(.failure(error)) }
    }
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        do {
            guard let response = downloadTask.response else { throw URLError(.badServerResponse) }
            // The system removes its temporary file after this callback returns.
            try FileManager.default.moveItem(at: location, to: savedArchive)
            finish(.success((savedArchive, response)))
        } catch { finish(.failure(error)) }
    }
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
                    totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        let expected = totalBytesExpectedToWrite > 0 ? totalBytesExpectedToWrite : 206_221_298
        let fraction = min(1, max(0, Double(totalBytesWritten) / Double(expected)))
        Task { @MainActor in update(fraction) }
    }
}

@MainActor
enum LocalAIRuntime {
    // Fixed official release; the archive must match GitHub's SHA256 and Ollama's Developer ID.
    static let archiveURL = URL(string: "https://github.com/ollama/ollama/releases/download/v0.40.3/Ollama-darwin.zip")!
    static let archiveSHA256 = "853396ad74619482cd99c1fab63be42161e892b3206922bd75b02d971550fb21"
    static let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("local.huiji.meetingtranscriber/Runtime", isDirectory: true)
    static var managedApp: URL { directory.appendingPathComponent("Ollama.app") }
    static var candidates: [URL] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        var paths = [URL(fileURLWithPath: "/Applications/Ollama.app/Contents/Resources/ollama"),
                home.appendingPathComponent("Applications/Ollama.app/Contents/Resources/ollama"),
                URL(fileURLWithPath: "/opt/homebrew/bin/ollama"), URL(fileURLWithPath: "/usr/local/bin/ollama"),
                managedApp.appendingPathComponent("Contents/Resources/ollama")]
        if let registered = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.electron.ollama") {
            paths.append(registered.appendingPathComponent("Contents/Resources/ollama"))
        }
        for path in (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":") where path.hasPrefix("/") {
            paths.append(URL(fileURLWithPath: String(path)).appendingPathComponent("ollama"))
        }
        return paths
    }
    static func executable(in paths: [URL]? = nil) -> URL? {
        (paths ?? candidates).first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }

    static func requireSpace(at url: URL, bytes: Int64) throws {
        let available = try url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]).volumeAvailableCapacityForImportantUsage
        if let available, available < bytes {
            throw MeetingError.message("磁盘空间不足，请至少释放 \(ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)) 后重试。")
        }
    }

    static func install(destination: URL? = nil, progress: @escaping @MainActor (String, Double?) -> Void) async throws {
        let destination = destination ?? managedApp
        if destination == managedApp, executable() != nil { return }
        if executable(in: [destination.appendingPathComponent("Contents/Resources/ollama")]) != nil { return }
        let parent = destination.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        try requireSpace(at: parent, bytes: 1_000_000_000)
        let delegate = RuntimeDownloadDelegate { progress("正在下载本地 AI 运行环境（约 206 MB）…", $0) }
        progress("正在连接官方运行环境下载地址…", nil)
        let (archive, response) = try await delegate.download(from: archiveURL)
        defer { try? FileManager.default.removeItem(at: archive) }
        guard let response = response as? HTTPURLResponse, response.statusCode == 200 else {
            throw MeetingError.message("运行环境下载失败，请检查网络后重试。")
        }
        try await installArchive(archive, destination: destination, progress: progress)
    }

    static func installArchive(_ archive: URL, destination: URL,
                               progress: @escaping (String, Double?) -> Void) async throws {
        progress("正在校验运行环境…", nil)
        let hash = Task.detached(priority: .utility) { () throws -> String in
            let handle = try FileHandle(forReadingFrom: archive)
            defer { try? handle.close() }
            var digest = SHA256()
            while let data = try handle.read(upToCount: 1_048_576), !data.isEmpty {
                try Task.checkCancellation()
                digest.update(data: data)
            }
            return digest.finalize().map { String(format: "%02x", $0) }.joined()
        }
        let digest = try await withTaskCancellationHandler { try await hash.value } onCancel: { hash.cancel() }
        guard digest == archiveSHA256 else {
            throw MeetingError.message("运行环境校验失败，未安装任何文件。请重新下载。")
        }
        let parent = destination.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        let stage = parent.appendingPathComponent(".install-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: stage, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: stage) }
        progress("正在安装并验证官方签名…", nil)
        try await run("/usr/bin/ditto", ["-x", "-k", archive.path, stage.path])
        let app = stage.appendingPathComponent("Ollama.app")
        try await run("/usr/bin/codesign", ["--verify", "--deep", "--strict", "-R",
            "=anchor apple generic and identifier com.electron.ollama and certificate leaf[subject.OU] = \"3MU9H2V9Y9\"", app.path])
        try Task.checkCancellation()
        guard executable(in: [app.appendingPathComponent("Contents/Resources/ollama")]) != nil else {
            throw MeetingError.message("运行环境不完整，请重试。")
        }
        guard !FileManager.default.fileExists(atPath: destination.path) else {
            throw MeetingError.message("会记的运行环境目录已存在，未覆盖已有文件。请检查“\(destination.path)”后重试。")
        }
        try FileManager.default.moveItem(at: app, to: destination)
    }

    private static func run(_ executable: String, _ arguments: [String]) async throws {
        try Task.checkCancellation()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        do { while process.isRunning { try await Task.sleep(for: .milliseconds(100)) } }
        catch {
            if process.isRunning { process.terminate() }
            // Wait for the extractor to stop before deleting its staging directory.
            await Task.detached {
                while process.isRunning { try? await Task.sleep(for: .milliseconds(100)) }
            }.value
            throw error
        }
        guard process.terminationStatus == 0 else {
            throw MeetingError.message("运行环境安装或签名验证失败，未更改已有环境。请重试。")
        }
    }
}
