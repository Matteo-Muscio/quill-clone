import Darwin
import Foundation

/// One owned child process at a time. Standard streams go to private files so
/// model logging cannot fill a pipe or copy a meeting transcript into app logs.
/// Cancellation waits for exit and escalates only this child if necessary.
final class NotesLocalProcess: @unchecked Sendable {
    struct Output: Sendable { var data: Data; var status: Int32 }
    private let lock = NSLock()
    private var process: Process?
    private var cancelled = false

    func run(executable: URL, arguments: [String], directory: URL,
             maximumOutputBytes: Int = 2_000_000) async throws -> Output {
        try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                let child = Process()
                child.executableURL = executable
                child.arguments = arguments
                child.currentDirectoryURL = directory
                // Do not inherit model/RPC/provider or DYLD overrides. This
                // worker uses only explicit local model and prompt paths.
                child.environment = ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "LANG": "en_US.UTF-8", "LLAMA_ARG_OFFLINE": "1"]
                child.standardInput = FileHandle.nullDevice
                let outputURL = directory.appendingPathComponent("output-\(UUID().uuidString).txt")
                let errorURL = directory.appendingPathComponent("stderr-\(UUID().uuidString).txt")
                do {
                    try Data().write(to: outputURL)
                    try Data().write(to: errorURL)
                    let output = try FileHandle(forWritingTo: outputURL)
                    let errors = try FileHandle(forWritingTo: errorURL)
                    child.standardOutput = output
                    child.standardError = errors
                    child.terminationHandler = { [self] terminated in
                        try? output.close()
                        try? errors.close()
                        defer {
                            try? FileManager.default.removeItem(at: outputURL)
                            try? FileManager.default.removeItem(at: errorURL)
                        }
                        let wasCancelled = lock.withLock { () -> Bool in
                            process = nil
                            return cancelled
                        }
                        if wasCancelled { continuation.resume(throwing: CancellationError()); return }
                        do {
                            let attributes = try FileManager.default.attributesOfItem(atPath: outputURL.path)
                            guard (attributes[.size] as? NSNumber)?.intValue ?? 0 <= maximumOutputBytes else {
                                throw MeetingNotesError.invalidOutput
                            }
                            let data = try Data(contentsOf: outputURL)
                            continuation.resume(returning: Output(data: data, status: terminated.terminationStatus))
                        } catch { continuation.resume(throwing: error) }
                    }
                    try lock.withLock {
                        guard !cancelled else { throw CancellationError() }
                        process = child
                        do { try child.run() } catch { process = nil; throw error }
                    }
                } catch {
                    child.terminationHandler = nil
                    try? (child.standardOutput as? FileHandle)?.close()
                    try? (child.standardError as? FileHandle)?.close()
                    try? FileManager.default.removeItem(at: outputURL)
                    try? FileManager.default.removeItem(at: errorURL)
                    continuation.resume(throwing: error)
                }
            }
        } onCancel: { self.cancel() }
    }

    func cancel() {
        let child = lock.withLock { () -> Process? in cancelled = true; return process }
        guard let child, child.isRunning else { return }
        child.terminate()
        Task.detached {
            try? await Task.sleep(for: .seconds(3))
            if child.isRunning { _ = Darwin.kill(child.processIdentifier, SIGKILL) }
        }
    }
}
