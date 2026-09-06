import ArgumentParser
import CryptoKit
import Darwin
import Foundation

/// Explicit, local-source updates for this fork. No downloaded executables,
/// privileged helper, scheduled checks, or changes to the user's checkout.
struct Update: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Build and install the latest main from Matteo-Muscio/quill-clone."
    )

    @Flag(name: .long, help: "Check main without building, stopping Quill, or installing.")
    var check = false

    @Option(name: .long, help: "Seconds to wait for Quill to become idle before installing (0–3600).")
    var wait: Double = 300

    func validate() throws {
        guard wait.isFinite, (0...3600).contains(wait) else {
            throw ValidationError("--wait must be between 0 and 3600 seconds")
        }
    }

    func run() throws {
        try LocalUpdater().run(checkOnly: check, waitSeconds: wait)
    }
}

struct UpdateFailure: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

struct UpdateCommand {
    let executable: String
    let arguments: [String]
    var directory: URL?
    var log: URL?

    struct Result {
        let status: Int32
        var output = ""
    }

    static func execute(_ command: Self) throws -> Result {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: command.executable)
        process.arguments = command.arguments
        process.currentDirectoryURL = command.directory
        var environment = ProcessInfo.processInfo.environment
        environment["LC_ALL"] = "C"
        environment["GIT_TERMINAL_PROMPT"] = "0"
        process.environment = environment

        if let log = command.log {
            let handle = try FileHandle(forWritingTo: log)
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: Data("\n> \(command.executable) \(command.arguments.joined(separator: " "))\n".utf8))
            process.standardOutput = handle
            process.standardError = handle
            try process.run()
            process.waitUntilExit()
            return Result(status: process.terminationStatus)
        }

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        // Drain before waiting so even a verbose failed command cannot fill
        // the pipe and deadlock the updater.
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return Result(status: process.terminationStatus, output: String(decoding: data, as: UTF8.self))
    }
}

struct UpdateReceipt: Codable, Equatable {
    let repository: String
    let revision: String
    let sha256: String
}

/// IO is injectable for transaction/failure tests; real tests use temporary
/// files while git, builds, and launchctl are replaced with deterministic fakes.
final class LocalUpdater {
    static let repository = "https://github.com/Matteo-Muscio/quill-clone.git"
    static let agentLabel = "com.digimata.quill"

    private let home: URL
    private let userID: uid_t
    private let execute: (UpdateCommand) throws -> UpdateCommand.Result
    private let requestExit: (Int32) -> Void
    private let sleep: (TimeInterval) -> Void
    private let uptime: () -> TimeInterval
    private let report: (String) -> Void
    private let files = FileManager.default

    init(
        home: URL = FileManager.default.homeDirectoryForCurrentUser,
        userID: uid_t = getuid(),
        execute: @escaping (UpdateCommand) throws -> UpdateCommand.Result = UpdateCommand.execute,
        requestExit: @escaping (Int32) -> Void = { pid in
            DistributedNotificationCenter.default().postNotificationName(
                UpdateHandoff.notificationName, object: String(pid), userInfo: nil,
                deliverImmediately: true
            )
        },
        sleep: @escaping (TimeInterval) -> Void = { Thread.sleep(forTimeInterval: $0) },
        uptime: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
        report: @escaping (String) -> Void = { print($0) }
    ) {
        self.home = home
        self.userID = userID
        self.execute = execute
        self.requestExit = requestExit
        self.sleep = sleep
        self.uptime = uptime
        self.report = report
    }

    var directory: URL { home.appendingPathComponent("Library/Application Support/quill/updates") }
    var receiptURL: URL { directory.appendingPathComponent("installed.json") }
    private var source: URL { directory.appendingPathComponent("source") }
    private var build: URL { directory.appendingPathComponent("build") }
    private var log: URL { directory.appendingPathComponent("update.log") }
    private var plist: URL { home.appendingPathComponent("Library/LaunchAgents/\(Self.agentLabel).plist") }
    private var service: String { "gui/\(userID)/\(Self.agentLabel)" }

    func run(checkOnly: Bool, waitSeconds: TimeInterval) throws {
        guard userID != 0, getuid() == geteuid() else {
            throw UpdateFailure("Run quill update as your normal user, without sudo.")
        }
        let installation = try readInstallation()
        try files.createDirectory(at: directory, withIntermediateDirectories: true,
                                  attributes: [.posixPermissions: 0o700])
        let lock = try UpdateLock(url: directory.appendingPathComponent("update.lock"))
        defer { lock.release() }

        report("Checking \(Self.repository) · main…")
        let remote = try checked("/usr/bin/git", ["ls-remote", "--exit-code", Self.repository, "refs/heads/main"])
        let fields = remote.split(whereSeparator: \.isWhitespace)
        guard fields.count == 2, fields[1] == "refs/heads/main",
              Self.isRevision(String(fields[0])) else {
            throw UpdateFailure("Git did not return a valid main revision; nothing was installed.")
        }
        let revision = String(fields[0])
        let installedHash = try Self.sha256(installation.binary)
        let recorded = (try? Data(contentsOf: receiptURL)).flatMap {
            try? JSONDecoder().decode(UpdateReceipt.self, from: $0)
        }
        let current = recorded.flatMap { receipt in
            receipt.repository == Self.repository && Self.isRevision(receipt.revision) ? receipt : nil
        }
        if current == UpdateReceipt(repository: Self.repository, revision: revision, sha256: installedHash) {
            report("Quill is up to date · \(revision.prefix(8))")
            return
        }
        if checkOnly {
            report(current.map { "Recorded revision: \($0.revision.prefix(8))\($0.sha256 == installedHash ? "" : " (installed binary has changed)"). Latest main: \(revision.prefix(8))." }
                   ?? "Installed revision is not recorded. Latest main: \(revision.prefix(8)).")
            report("Run quill update to build, validate, and install this revision.")
            return
        }

        guard files.isWritableFile(atPath: installation.binary.path),
              files.isWritableFile(atPath: installation.binary.deletingLastPathComponent().path) else {
            throw UpdateFailure("The installed binary is not user-writable: \(installation.binary.path). Use a user-owned installation; this updater does not use sudo.")
        }
        try Data().write(to: log, options: .atomic)
        report("Building and testing \(revision.prefix(8)); Quill can keep running.\nBuild log: \(log.path)")
        try prepareSource(revision: revision)
        _ = try checked("/usr/bin/xcrun", ["--find", "swift"])
        for arguments in [
            ["swift", "test", "--scratch-path", build.path],
            ["swift", "test", "--scratch-path", build.path, "-c", "release"],
            ["swift", "build", "--scratch-path", build.path, "-c", "release"],
        ] {
            _ = try checked("/usr/bin/xcrun", arguments, directory: source, log: log)
        }
        let binaryDirectory = try checked(
            "/usr/bin/xcrun", ["swift", "build", "--scratch-path", build.path, "-c", "release", "--show-bin-path"],
            directory: source
        ).trimmingCharacters(in: .whitespacesAndNewlines)
        guard binaryDirectory.hasPrefix("/") else { throw UpdateFailure("Swift did not report a binary directory.") }
        let candidate = URL(fileURLWithPath: binaryDirectory).appendingPathComponent("quill")
        let staged = try stage(candidate, beside: installation.binary)
        defer { try? files.removeItem(at: staged) }
        _ = try checked("/usr/bin/codesign", ["--verify", "--strict", staged.path])
        _ = try checked(staged.path, ["--help"])
        _ = try checked(staged.path, ["update", "--help"])
        let candidateHash = try Self.sha256(staged)
        let receipt = UpdateReceipt(repository: Self.repository, revision: revision, sha256: candidateHash)

        // Prepare every backup before asking a running daemon to leave.
        try ensureUnchanged(installation, expectedHash: installedHash)
        let backup = directory.appendingPathComponent("backups/\(UUID().uuidString)")
        try files.createDirectory(at: backup, withIntermediateDirectories: true)
        try files.copyItem(at: installation.binary, to: backup.appendingPathComponent("quill"))
        try installation.plistData.write(to: backup.appendingPathComponent("launch-agent.plist"), options: .atomic)
        let previousReceipt = try files.fileExists(atPath: receiptURL.path) ? Data(contentsOf: receiptURL) : nil
        if let previousReceipt {
            try previousReceipt.write(to: backup.appendingPathComponent("installed.json"), options: .atomic)
        }

        report("Validation passed. Waiting up to \(Int(waitSeconds)) seconds for Quill to become idle…")
        try waitForIdleExit(binary: installation.binary, seconds: waitSeconds)
        try ensureUnchanged(installation, expectedHash: installedHash)
        try unloadStoppedJob(binary: installation.binary)

        // The short replacement/restart transaction must finish even if the
        // terminal receives Ctrl-C. SIGKILL/power loss still leave the backup.
        let previousINT = signal(SIGINT, SIG_IGN)
        let previousTERM = signal(SIGTERM, SIG_IGN)
        defer {
            signal(SIGINT, previousINT)
            signal(SIGTERM, previousTERM)
        }
        do {
            try rename(staged, to: installation.binary)
            try JSONEncoder().encode(receipt).write(to: receiptURL, options: .atomic)
            try bootstrap()
            try verifyRunning(binary: installation.binary)
        } catch {
            let failure = error.localizedDescription
            do {
                // Never force-stop a new recording, even during rollback.
                try waitForIdleExit(binary: installation.binary, seconds: 5)
                try unloadStoppedJob(binary: installation.binary)
                let previous = try stage(backup.appendingPathComponent("quill"), beside: installation.binary)
                try rename(previous, to: installation.binary)
                if let previousReceipt {
                    try previousReceipt.write(to: receiptURL, options: .atomic)
                } else if files.fileExists(atPath: receiptURL.path) {
                    try files.removeItem(at: receiptURL)
                }
                try bootstrap()
                try verifyRunning(binary: installation.binary)
            } catch {
                throw UpdateFailure("Update could not be verified: \(failure)\nRollback could not finish: \(error.localizedDescription)\nBackup retained at \(backup.path). Check Quill before recording.")
            }
            throw UpdateFailure("Update failed: \(failure)\nThe previous binary was restored and restarted. Backup: \(backup.path)")
        }
        report("Updated and running · \(revision.prefix(8))\nInstalled: \(installation.binary.path)\nRollback copy: \(backup.path)")
    }

    private struct Installation {
        let binary: URL
        let plistData: Data
    }

    private func readInstallation() throws -> Installation {
        let data: Data
        do { data = try Data(contentsOf: plist) }
        catch { throw UpdateFailure("No Quill LaunchAgent found at \(plist.path). Install launch-at-login first.") }
        guard let value = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              value["Label"] as? String == Self.agentLabel,
              let arguments = value["ProgramArguments"] as? [String],
              let path = arguments.first, path.hasPrefix("/"),
              arguments.count == 1 || arguments[1] == "run" else {
            throw UpdateFailure("The LaunchAgent does not describe a Quill daemon; nothing was installed.")
        }
        let binary = URL(fileURLWithPath: path).standardizedFileURL
        let attributes = try files.attributesOfItem(atPath: binary.path)
        guard binary.lastPathComponent == "quill", attributes[.type] as? FileAttributeType == .typeRegular,
              (attributes[.ownerAccountID] as? NSNumber)?.uint32Value == userID,
              files.isExecutableFile(atPath: binary.path) else {
            throw UpdateFailure("The LaunchAgent must point to a regular, user-owned executable named quill.")
        }
        return Installation(binary: binary, plistData: data)
    }

    private func prepareSource(revision: String) throws {
        let freshClone = !files.fileExists(atPath: source.path)
        if freshClone {
            _ = try checked("/usr/bin/git", ["clone", "--no-checkout", "--single-branch", "--branch", "main", Self.repository, source.path], log: log)
        }
        let origin = try checked("/usr/bin/git", ["remote", "get-url", "origin"], directory: source)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard origin == Self.repository else {
            throw UpdateFailure("The update cache points to a different repository. Refusing to use it: \(source.path)")
        }
        // Only a clone created by this invocation may have staged deletions.
        // Existing caches must be clean even when the manifest was removed.
        if !freshClone {
            let changes = try checked("/usr/bin/git", ["status", "--porcelain", "--untracked-files=all"], directory: source)
            guard changes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw UpdateFailure("The update cache has local changes. Move it aside before retrying: \(source.path)")
            }
        }
        _ = try checked("/usr/bin/git", ["fetch", "--no-tags", "origin", "main"], directory: source, log: log)
        // Use the immutable revision checked at the start, even if main has
        // advanced during download. Missing commits fail before installation.
        _ = try checked("/usr/bin/git", ["checkout", "--detach", revision], directory: source, log: log)
        let head = try checked("/usr/bin/git", ["rev-parse", "HEAD"], directory: source)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard head == revision else { throw UpdateFailure("The update checkout is not the requested revision.") }
    }

    private func ensureUnchanged(_ installation: Installation, expectedHash: String) throws {
        guard try Data(contentsOf: plist) == installation.plistData,
              try Self.sha256(installation.binary) == expectedHash else {
            throw UpdateFailure("The installed binary or LaunchAgent changed during the build. Retry the update.")
        }
    }

    private struct Job {
        let loaded: Bool
        let pid: Int32?
    }

    private func job(binary: URL) throws -> Job {
        let result = try execute(UpdateCommand(executable: "/bin/launchctl", arguments: ["print", service]))
        if result.status == 113 { return Job(loaded: false, pid: nil) }
        guard result.status == 0 else { throw UpdateFailure("Could not inspect Quill's LaunchAgent: \(result.output)") }
        let lines = result.output.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
        guard lines.contains("program = \(binary.path)") else {
            throw UpdateFailure("The running LaunchAgent points to a different executable. Refusing to stop it.")
        }
        let pid: Int32?
        if let line = lines.first(where: { $0.hasPrefix("pid = ") }) {
            guard let value = Int32(line.dropFirst(6)), value > 0 else {
                throw UpdateFailure("LaunchAgent returned an invalid process identifier; refusing to stop it.")
            }
            pid = value
        } else {
            guard lines.first(where: { $0.hasPrefix("state = ") }) == "state = not running" else {
                throw UpdateFailure("LaunchAgent process state is unknown; refusing to stop it.")
            }
            pid = nil
        }
        return Job(loaded: true, pid: pid)
    }

    private func waitForIdleExit(binary: URL, seconds: TimeInterval) throws {
        let deadline = uptime() + seconds
        while let pid = try job(binary: binary).pid {
            guard uptime() < deadline else {
                throw UpdateFailure("Quill did not become idle; nothing was force-stopped. Finish recording, transcription, or model preparation and retry. An older Quill may need to be quit from its menu first.")
            }
            requestExit(pid)
            sleep(min(1, max(0, deadline - uptime())))
        }
    }

    private func unloadStoppedJob(binary: URL) throws {
        let state = try job(binary: binary)
        guard state.pid == nil else { throw UpdateFailure("Quill restarted before installation. Retry when idle.") }
        if state.loaded {
            _ = try checked("/bin/launchctl", ["bootout", service])
        }
    }

    private func bootstrap() throws {
        _ = try checked("/bin/launchctl", ["bootstrap", "gui/\(userID)", plist.path])
    }

    private func verifyRunning(binary: URL) throws {
        let deadline = uptime() + 10
        while uptime() < deadline {
            if let pid = try job(binary: binary).pid {
                sleep(2)
                if try job(binary: binary).pid == pid { return }
                break
            }
            sleep(1)
        }
        throw UpdateFailure("Quill did not stay running after launch. Inspect its LaunchAgent logs.")
    }

    private func checked(_ executable: String, _ arguments: [String], directory: URL? = nil, log: URL? = nil) throws -> String {
        let result = try execute(UpdateCommand(executable: executable, arguments: arguments, directory: directory, log: log))
        guard result.status == 0 else {
            throw UpdateFailure("\(URL(fileURLWithPath: executable).lastPathComponent) \(arguments.first ?? "") failed (\(result.status)). \(log.map { "See \($0.path)" } ?? result.output)")
        }
        return result.output
    }

    private func stage(_ binary: URL, beside destination: URL) throws -> URL {
        let staged = destination.deletingLastPathComponent().appendingPathComponent(".quill-update-\(UUID().uuidString)")
        try files.copyItem(at: binary, to: staged)
        return staged
    }

    private func rename(_ source: URL, to destination: URL) throws {
        guard Darwin.rename(source.path, destination.path) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
    }

    static func sha256(_ url: URL) throws -> String {
        SHA256.hash(data: try Data(contentsOf: url)).map { String(format: "%02x", $0) }.joined()
    }

    private static func isRevision(_ value: String) -> Bool {
        value.count == 40 && value.allSatisfy { "0123456789abcdef".contains($0) }
    }
}

private final class UpdateLock {
    private var descriptor: Int32
    init(url: URL) throws {
        descriptor = open(url.path, O_CREAT | O_RDWR | O_CLOEXEC | O_NOFOLLOW, 0o600)
        guard descriptor >= 0 else { throw UpdateFailure("Could not open the update lock: \(url.path)") }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            close(descriptor)
            descriptor = -1
            throw UpdateFailure("Another Quill update is already running.")
        }
    }
    func release() {
        if descriptor >= 0 {
            flock(descriptor, LOCK_UN)
            close(descriptor)
            descriptor = -1
        }
    }
    deinit { release() }
}
