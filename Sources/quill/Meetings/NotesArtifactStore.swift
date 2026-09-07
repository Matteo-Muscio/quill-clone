import CryptoKit
import Foundation

actor NotesArtifactStore {
    static let shared = NotesArtifactStore()
    static let runtimeVersion = "b10837"
    /// Official release artifact SHA-256 published by GitHub, checked 2026-09-07.
    /// https://github.com/ggml-org/llama.cpp/releases/tag/b10837 (MIT license).
    static let runtime = NotesArtifact(
        url: URL(string: "https://github.com/ggml-org/llama.cpp/releases/download/b10837/llama-b10837-bin-macos-arm64.tar.gz")!,
        filename: "llama-b10837-bin-macos-arm64.tar.gz", bytes: 11_137_232,
        sha256: "587b7abae134fc59ead2c4ab2b3a22cb33ed28fdb1bcd4ebf76eccb9b99fc2ac")

    struct Installation: Sendable { let modelURL: URL; let completionURL: URL; let tokenizerURL: URL }
    private struct Receipt: Codable { let sha256: String; let bytes: Int64 }
    private let root: URL
    private var downloading = false

    init(root: URL = NotesModelSettings.root) { self.root = root }

    func isInstalled(_ model: NotesModel) -> Bool {
        #if !arch(arm64)
        return false
        #else
        return validReceipt(for: model.artifact, file: modelURL(model)) && runtimeInstalled()
        #endif
    }

    func installation(for model: NotesModel) throws -> Installation {
        guard isInstalled(model) else { throw MeetingNotesError.modelNotInstalled(model) }
        return Installation(modelURL: modelURL(model), completionURL: runtimeFolder.appendingPathComponent("llama-completion"),
                            tokenizerURL: runtimeFolder.appendingPathComponent("llama-tokenize"))
    }

    func download(_ model: NotesModel, progress: @escaping @Sendable (Double) -> Void,
                  verifying: @escaping @Sendable () -> Void) async throws {
        #if !arch(arm64)
        throw MeetingNotesError.unsupportedMac
        #else
        guard !downloading else { throw MeetingNotesError.busy }
        downloading = true
        defer { downloading = false }
        try Task.checkCancellation()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        let stage = root.appendingPathComponent("staging/\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: stage, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: stage) }

        if !runtimeInstalled() {
            let archive = stage.appendingPathComponent(Self.runtime.filename)
            try await NotesArtifactDownload().download(Self.runtime, to: archive) { progress($0 * 0.02) }
            try Self.verify(archive, artifact: Self.runtime)
            let extraction = stage.appendingPathComponent("runtime", isDirectory: true)
            try FileManager.default.createDirectory(at: extraction, withIntermediateDirectories: true)
            let tar = try await NotesLocalProcess().run(executable: URL(fileURLWithPath: "/usr/bin/tar"),
                arguments: ["-xzf", archive.path, "-C", extraction.path], directory: stage)
            guard tar.status == 0 else { throw MeetingNotesError.runtimeInstallation }
            let folder = extraction.appendingPathComponent("llama-\(Self.runtimeVersion)", isDirectory: true)
            let probe = try await NotesLocalProcess().run(executable: folder.appendingPathComponent("llama-completion"),
                                                          arguments: ["--version"], directory: stage)
            guard probe.status == 0 else { throw MeetingNotesError.runtimeInstallation }
            try Task.checkCancellation()
            try Self.writeReceipt(Self.runtime, to: extraction.appendingPathComponent("receipt.json"))
            try Self.installDirectory(extraction, at: runtimeDirectory)
        }
        progress(0.02)

        let destination = modelURL(model)
        if !validReceipt(for: model.artifact, file: destination) {
            // Reuse a complete manually staged/downloaded artifact only after
            // hashing it. A matching file size alone never marks it installed.
            let reusable = FileManager.default.fileExists(atPath: destination.path)
                && (try? Self.verify(destination, artifact: model.artifact)) != nil
            if !reusable {
                let partial = stage.appendingPathComponent(model.artifact.filename)
                try await NotesArtifactDownload().download(model.artifact, to: partial) { progress(0.02 + $0 * 0.96) }
                verifying()
                try Self.verify(partial, artifact: model.artifact)
                try Task.checkCancellation()
                try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true,
                                                        attributes: [.posixPermissions: 0o700])
                try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: partial.path)
                if FileManager.default.fileExists(atPath: destination.path) {
                    _ = try FileManager.default.replaceItemAt(destination, withItemAt: partial)
                } else { try FileManager.default.moveItem(at: partial, to: destination) }
            }
            verifying()
            try Task.checkCancellation()
            try Self.writeReceipt(model.artifact, to: receiptURL(for: destination))
            let attribution = "\(model.displayName) — Q4_K_M\nPublisher: \(model.sourceURL.absoluteString)\nArtifact: \(model.artifact.url.absoluteString)\nSHA-256: \(model.artifact.sha256)\nLicense: Apache-2.0 (https://www.apache.org/licenses/LICENSE-2.0)\n"
            try attribution.write(to: destination.deletingLastPathComponent().appendingPathComponent("SOURCE.txt"),
                                  atomically: true, encoding: .utf8)
        }
        try Task.checkCancellation()
        progress(1)
        #endif
    }

    private var runtimeDirectory: URL { root.appendingPathComponent("runtime/\(Self.runtimeVersion)", isDirectory: true) }
    private var runtimeFolder: URL { runtimeDirectory.appendingPathComponent("llama-\(Self.runtimeVersion)", isDirectory: true) }
    private func modelURL(_ model: NotesModel) -> URL {
        root.appendingPathComponent("models/\(model.rawValue)/\(model.artifact.filename)")
    }
    private func receiptURL(for file: URL) -> URL { file.appendingPathExtension("verified.json") }
    private func validReceipt(for artifact: NotesArtifact, file: URL) -> Bool {
        guard let data = try? Data(contentsOf: receiptURL(for: file)),
              let receipt = try? JSONDecoder().decode(Receipt.self, from: data),
              receipt.sha256 == artifact.sha256, receipt.bytes == artifact.bytes,
              let attributes = try? FileManager.default.attributesOfItem(atPath: file.path),
              (attributes[.size] as? NSNumber)?.int64Value == artifact.bytes else { return false }
        return true
    }
    private func runtimeInstalled() -> Bool {
        guard let data = try? Data(contentsOf: runtimeDirectory.appendingPathComponent("receipt.json")),
              let receipt = try? JSONDecoder().decode(Receipt.self, from: data),
              receipt.sha256 == Self.runtime.sha256, receipt.bytes == Self.runtime.bytes else { return false }
        return ["llama-completion", "llama-tokenize"].allSatisfy {
            FileManager.default.isExecutableFile(atPath: runtimeFolder.appendingPathComponent($0).path)
        }
    }
    private static func writeReceipt(_ artifact: NotesArtifact, to url: URL) throws {
        try JSONEncoder().encode(Receipt(sha256: artifact.sha256, bytes: artifact.bytes)).write(to: url, options: .atomic)
    }
    static func verify(_ url: URL, artifact: NotesArtifact) throws {
        try Task.checkCancellation()
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        guard (attributes[.size] as? NSNumber)?.int64Value == artifact.bytes else { throw MeetingNotesError.invalidDownload }
        let file = try FileHandle(forReadingFrom: url)
        defer { try? file.close() }
        var hash = SHA256()
        while let data = try file.read(upToCount: 1_048_576), !data.isEmpty {
            try Task.checkCancellation()
            hash.update(data: data)
        }
        let value = hash.finalize().map { String(format: "%02x", $0) }.joined()
        guard value == artifact.sha256 else { throw MeetingNotesError.invalidDownload }
    }
    private static func installDirectory(_ candidate: URL, at destination: URL) throws {
        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        let backup = destination.deletingLastPathComponent().appendingPathComponent("replaced-\(UUID().uuidString)")
        let exists = FileManager.default.fileExists(atPath: destination.path)
        if exists { try FileManager.default.moveItem(at: destination, to: backup) }
        do { try FileManager.default.moveItem(at: candidate, to: destination) }
        catch {
            if exists { try? FileManager.default.moveItem(at: backup, to: destination) }
            throw error
        }
        if exists { try? FileManager.default.removeItem(at: backup) }
    }
}

/// URLSession's disk download avoids buffering a multi-gigabyte GGUF in memory.
private final class NotesArtifactDownload: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var task: URLSessionDownloadTask?
    private var session: URLSession?
    private var continuation: CheckedContinuation<Void, Error>?
    private var destination: URL?
    private var expectedBytes: Int64 = 0
    private var progress: (@Sendable (Double) -> Void)?
    private var resultError: Error?
    private var cancelled = false

    func download(_ artifact: NotesArtifact, to destination: URL,
                  progress: @escaping @Sendable (Double) -> Void) async throws {
        try await withTaskCancellationHandler {
            try Task.checkCancellation()
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                lock.withLock {
                    guard !cancelled else { continuation.resume(throwing: CancellationError()); return }
                    self.continuation = continuation
                    self.destination = destination
                    self.expectedBytes = artifact.bytes
                    self.progress = progress
                    let config = URLSessionConfiguration.ephemeral
                    config.timeoutIntervalForRequest = 60
                    config.timeoutIntervalForResource = 3600
                    let session = URLSession(configuration: config, delegate: self, delegateQueue: nil)
                    self.session = session
                    var request = URLRequest(url: artifact.url)
                    request.setValue("quill-local-notes", forHTTPHeaderField: "User-Agent")
                    let task = session.downloadTask(with: request)
                    self.task = task
                    task.resume()
                }
            }
        } onCancel: {
            let task = self.lock.withLock { self.cancelled = true; return self.task }
            task?.cancel()
        }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        let values = lock.withLock { (progress, expectedBytes) }
        values.0?(min(1, Double(totalBytesWritten) / Double(max(1, values.1))))
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        do {
            guard let response = downloadTask.response as? HTTPURLResponse, response.statusCode == 200,
                  let destination = lock.withLock({ destination }) else { throw MeetingNotesError.invalidDownload }
            try FileManager.default.moveItem(at: location, to: destination)
        } catch { lock.withLock { resultError = error } }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        let state = lock.withLock { () -> (CheckedContinuation<Void, Error>?, Error?) in
            let continuation = self.continuation
            self.continuation = nil
            let finalError: Error? = cancelled ? CancellationError() : (error ?? resultError)
            self.task = nil
            self.session = nil
            return (continuation, finalError)
        }
        session.finishTasksAndInvalidate()
        if let error = state.1 { state.0?.resume(throwing: error) } else { state.0?.resume() }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        completionHandler(request.url?.scheme == "https" ? request : nil)
    }
}
