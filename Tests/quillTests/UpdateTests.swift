import Foundation
import XCTest
@testable import quill

final class UpdateTests: XCTestCase {
    func testCheckOnlyFetchesCorrectForkWithoutBuildingOrStopping() throws {
        let fixture = try fixture()
        try fixture.updater().run(checkOnly: true, waitSeconds: 0)
        XCTAssertEqual(try Data(contentsOf: fixture.binary), fixture.oldBinary)
        XCTAssertEqual(fixture.pid, 41)
        XCTAssertEqual(fixture.requests, 0)
        XCTAssertFalse(fixture.commands.contains { $0.executable == "/usr/bin/xcrun" })
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.receipt.path))
        XCTAssertEqual(fixture.commands.first?.arguments,
                       ["ls-remote", "--exit-code", LocalUpdater.repository, "refs/heads/main"])
        XCTAssertTrue(fixture.messages.contains { $0.contains("not recorded") })
    }

    func testMatchingReceiptAndBinarySkipBuildAndRestart() throws {
        let fixture = try fixture()
        try fixture.writeReceipt(revision: fixture.revision)
        try fixture.updater().run(checkOnly: false, waitSeconds: 5)
        XCTAssertTrue(fixture.messages.contains { $0.contains("up to date") })
        XCTAssertEqual(fixture.requests, 0)
        XCTAssertEqual(fixture.bootstraps, 0)
        XCTAssertEqual(fixture.commands.count, 1)
    }

    func testChangedBinaryCannotBeReportedUpToDate() throws {
        let fixture = try fixture()
        try fixture.writeReceipt(revision: fixture.revision)
        try Data("locally changed executable".utf8).write(to: fixture.binary)
        try fixture.updater().run(checkOnly: true, waitSeconds: 0)
        XCTAssertFalse(fixture.messages.contains { $0.contains("up to date") })
        XCTAssertTrue(fixture.messages.contains { $0.contains("installed binary has changed") })
        XCTAssertEqual(fixture.requests, 0)
    }

    func testSuccessValidatesBeforeQuiescingAndPreservesRollbackAndAgent() throws {
        let fixture = try fixture()
        let plist = try Data(contentsOf: fixture.plist)
        try fixture.updater().run(checkOnly: false, waitSeconds: 5)
        XCTAssertEqual(try Data(contentsOf: fixture.binary), fixture.newBinary)
        XCTAssertEqual(try Data(contentsOf: fixture.plist), plist)
        XCTAssertEqual(fixture.requests, 1)
        XCTAssertEqual(fixture.binaryAtRequest, fixture.oldBinary)
        XCTAssertEqual(fixture.bootstraps, 1)
        XCTAssertNotNil(fixture.pid)
        XCTAssertTrue(fixture.loaded)
        let receipt = try JSONDecoder().decode(UpdateReceipt.self, from: Data(contentsOf: fixture.receipt))
        XCTAssertEqual(receipt.repository, LocalUpdater.repository)
        XCTAssertEqual(receipt.revision, fixture.revision)
        XCTAssertEqual(receipt.sha256, try LocalUpdater.sha256(fixture.binary))
        XCTAssertEqual(try Data(contentsOf: fixture.onlyBackup().appendingPathComponent("quill")), fixture.oldBinary)
        let builds = fixture.commands.filter { $0.executable == "/usr/bin/xcrun" }
        XCTAssertTrue(builds.contains { $0.arguments == ["swift", "test", "--scratch-path", fixture.build.path] })
        XCTAssertTrue(builds.contains { $0.arguments == ["swift", "test", "--scratch-path", fixture.build.path, "-c", "release"] })
        XCTAssertTrue(builds.contains { $0.arguments == ["swift", "build", "--scratch-path", fixture.build.path, "-c", "release"] })
        XCTAssertTrue(fixture.commands.contains { $0.executable == "/usr/bin/codesign" && $0.arguments.prefix(2) == ["--verify", "--strict"] })
        XCTAssertTrue(fixture.commands.contains { $0.arguments == ["update", "--help"] })
        XCTAssertFalse(fixture.commands.contains { $0.arguments.contains("kill") || $0.arguments.contains("kickstart") })
        XCTAssertTrue(fixture.messages.last?.contains("Updated and running") == true)
    }

    func testBuildAndValidationFailuresLeaveRunningInstallationUntouched() throws {
        for failure in ["debug tests", "release tests", "release build", "signature", "CLI probe"] {
            let fixture = try fixture()
            fixture.failure = failure
            XCTAssertThrowsError(try fixture.updater().run(checkOnly: false, waitSeconds: 5), failure)
            XCTAssertEqual(try Data(contentsOf: fixture.binary), fixture.oldBinary, failure)
            XCTAssertEqual(fixture.pid, 41, failure)
            XCTAssertEqual(fixture.requests, 0, failure)
            XCTAssertEqual(fixture.bootouts, 0, failure)
            XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.receipt.path), failure)
        }
    }

    func testBusyOrOlderDaemonTimesOutWithoutForceOrReplacement() throws {
        let fixture = try fixture()
        fixture.exitsOnRequest = false
        XCTAssertThrowsError(try fixture.updater().run(checkOnly: false, waitSeconds: 3)) { error in
            XCTAssertTrue(error.localizedDescription.contains("older Quill"))
            XCTAssertTrue(error.localizedDescription.contains("nothing was force-stopped"))
        }
        XCTAssertEqual(fixture.clock, 3)
        XCTAssertEqual(fixture.requests, 3)
        XCTAssertEqual(fixture.pid, 41)
        XCTAssertEqual(fixture.bootouts, 0)
        XCTAssertEqual(try Data(contentsOf: fixture.binary), fixture.oldBinary)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.receipt.path))
    }

    func testZeroWaitDoesNotRequestExitOfRunningApp() throws {
        let fixture = try fixture()
        XCTAssertThrowsError(try fixture.updater().run(checkOnly: false, waitSeconds: 0))
        XCTAssertEqual(fixture.requests, 0)
        XCTAssertEqual(fixture.bootouts, 0)
        XCTAssertEqual(try Data(contentsOf: fixture.binary), fixture.oldBinary)
    }

    func testStoppedAgentCanUpdateWithoutAnIdleRequest() throws {
        let fixture = try fixture()
        fixture.pid = nil
        try fixture.updater().run(checkOnly: false, waitSeconds: 0)
        XCTAssertEqual(fixture.requests, 0)
        XCTAssertEqual(fixture.bootouts, 1)
        XCTAssertEqual(try Data(contentsOf: fixture.binary), fixture.newBinary)
    }

    func testUnloadedAgentCanUpdateAndRestart() throws {
        let fixture = try fixture()
        fixture.loaded = false
        fixture.pid = nil
        try fixture.updater().run(checkOnly: false, waitSeconds: 0)
        XCTAssertEqual(fixture.bootouts, 0)
        XCTAssertEqual(fixture.bootstraps, 1)
        XCTAssertNotNil(fixture.pid)
    }

    func testFailedRestartRestoresExactBinaryAndPreviousReceipt() throws {
        let fixture = try fixture()
        try fixture.writeReceipt(revision: String(repeating: "b", count: 40))
        let oldReceipt = try Data(contentsOf: fixture.receipt)
        fixture.failure = "first bootstrap"
        XCTAssertThrowsError(try fixture.updater().run(checkOnly: false, waitSeconds: 5)) { error in
            XCTAssertTrue(error.localizedDescription.contains("previous binary was restored and restarted"))
        }
        XCTAssertEqual(try Data(contentsOf: fixture.binary), fixture.oldBinary)
        XCTAssertEqual(try Data(contentsOf: fixture.receipt), oldReceipt)
        XCTAssertEqual(fixture.bootstraps, 2)
        XCTAssertNotNil(fixture.pid)
        XCTAssertFalse(fixture.messages.contains { $0.contains("Updated and running") })
    }

    func testEarlyExitAfterBootstrapAlsoRollsBack() throws {
        let fixture = try fixture()
        fixture.failure = "first startup exits"
        XCTAssertThrowsError(try fixture.updater().run(checkOnly: false, waitSeconds: 5))
        XCTAssertEqual(try Data(contentsOf: fixture.binary), fixture.oldBinary)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.receipt.path))
        XCTAssertEqual(fixture.bootstraps, 2)
        XCTAssertNotNil(fixture.pid)
    }

    func testRollbackFailureIsReportedWithRecoveryCopyRetained() throws {
        let fixture = try fixture()
        fixture.failure = "all bootstraps"
        XCTAssertThrowsError(try fixture.updater().run(checkOnly: false, waitSeconds: 5)) { error in
            XCTAssertTrue(error.localizedDescription.contains("Rollback could not finish"))
            XCTAssertTrue(error.localizedDescription.contains("Backup retained"))
        }
        XCTAssertEqual(try Data(contentsOf: fixture.onlyBackup().appendingPathComponent("quill")), fixture.oldBinary)
        XCTAssertEqual(try Data(contentsOf: fixture.binary), fixture.oldBinary)
        XCTAssertNil(fixture.pid)
    }

    func testUnknownNewProcessStateDoesNotTriggerForcedRollback() throws {
        let fixture = try fixture()
        fixture.failure = "unknown state after bootstrap"
        XCTAssertThrowsError(try fixture.updater().run(checkOnly: false, waitSeconds: 5)) { error in
            XCTAssertTrue(error.localizedDescription.contains("Rollback could not finish"))
        }
        XCTAssertEqual(fixture.bootouts, 1, "Only the safely quiesced old daemon may be unloaded")
        XCTAssertEqual(try Data(contentsOf: fixture.binary), fixture.newBinary)
        XCTAssertNotNil(fixture.pid)
        XCTAssertEqual(try Data(contentsOf: fixture.onlyBackup().appendingPathComponent("quill")), fixture.oldBinary)
    }

    func testBinaryChangedDuringBuildIsPreserved() throws {
        let fixture = try fixture()
        fixture.onBuild = { try Data("another installation".utf8).write(to: fixture.binary) }
        XCTAssertThrowsError(try fixture.updater().run(checkOnly: false, waitSeconds: 5)) { error in
            XCTAssertTrue(error.localizedDescription.contains("changed during the build"))
        }
        XCTAssertEqual(try Data(contentsOf: fixture.binary), Data("another installation".utf8))
        XCTAssertEqual(fixture.requests, 0)
        XCTAssertEqual(fixture.bootouts, 0)
    }

    func testChangedAgentDuringBuildIsPreserved() throws {
        let fixture = try fixture()
        fixture.onBuild = { try Data("edited plist".utf8).write(to: fixture.plist) }
        XCTAssertThrowsError(try fixture.updater().run(checkOnly: false, waitSeconds: 5))
        XCTAssertEqual(try Data(contentsOf: fixture.plist), Data("edited plist".utf8))
        XCTAssertEqual(try Data(contentsOf: fixture.binary), fixture.oldBinary)
        XCTAssertEqual(fixture.requests, 0)
    }

    func testWrongRepositoryOrDirtyCacheNeverBuildsOrStops() throws {
        for failure in ["wrong repository", "dirty cache", "wrong checkout", "malformed remote"] {
            let fixture = try fixture()
            fixture.failure = failure
            if failure == "dirty cache" {
                // Existing cache with a deleted manifest must still be checked.
                try FileManager.default.createDirectory(at: fixture.source, withIntermediateDirectories: true)
            }
            XCTAssertThrowsError(try fixture.updater().run(checkOnly: false, waitSeconds: 5), failure)
            XCTAssertFalse(fixture.commands.contains { $0.arguments.first == "swift" }, failure)
            XCTAssertEqual(fixture.requests, 0, failure)
            XCTAssertEqual(try Data(contentsOf: fixture.binary), fixture.oldBinary, failure)
        }
    }

    func testDifferentLoadedProgramIsNeverStopped() throws {
        let fixture = try fixture()
        fixture.failure = "different loaded program"
        XCTAssertThrowsError(try fixture.updater().run(checkOnly: false, waitSeconds: 5))
        XCTAssertEqual(fixture.requests, 0)
        XCTAssertEqual(fixture.bootouts, 0)
        XCTAssertEqual(try Data(contentsOf: fixture.binary), fixture.oldBinary)
    }

    func testMalformedOrMissingPIDNeverCountsAsStopped() throws {
        for failure in ["malformed pid", "overflow pid", "missing running pid"] {
            let fixture = try fixture()
            fixture.failure = failure
            XCTAssertThrowsError(try fixture.updater().run(checkOnly: false, waitSeconds: 5))
            XCTAssertEqual(fixture.requests, 0)
            XCTAssertEqual(fixture.bootouts, 0)
            XCTAssertEqual(try Data(contentsOf: fixture.binary), fixture.oldBinary)
        }
    }

    func testInvalidAgentCannotTargetUnrelatedExecutable() throws {
        let fixture = try fixture()
        let data = try PropertyListSerialization.data(
            fromPropertyList: ["Label": "unrelated.agent", "ProgramArguments": [fixture.binary.path, "run"]],
            format: .xml, options: 0
        )
        try data.write(to: fixture.plist)
        XCTAssertThrowsError(try fixture.updater().run(checkOnly: false, waitSeconds: 5))
        XCTAssertTrue(fixture.commands.isEmpty)
    }

    func testConcurrentUpdateIsRejectedAndLockIsReleasedAfterSuccess() throws {
        let fixture = try fixture()
        var rejected = false
        fixture.onExitRequest = {
            do { try fixture.updater().run(checkOnly: true, waitSeconds: 0) }
            catch { rejected = error.localizedDescription.contains("already running") }
        }
        try fixture.updater().run(checkOnly: false, waitSeconds: 5)
        XCTAssertTrue(rejected)
        fixture.onExitRequest = nil
        try fixture.updater().run(checkOnly: true, waitSeconds: 0)
        XCTAssertTrue(fixture.messages.last?.contains("up to date") == true)
    }

    func testCommandRunnerDrainsLargeOutputWithoutDeadlock() throws {
        let result = try UpdateCommand.execute(UpdateCommand(
            executable: "/bin/sh",
            arguments: ["-c", "dd if=/dev/zero bs=1024 count=128 2>/dev/null; printf done >&2"]
        ))
        XCTAssertEqual(result.status, 0)
        XCTAssertEqual(result.output.utf8.count, 128 * 1024 + 4)
        XCTAssertTrue(result.output.hasSuffix("done"))
    }

    private func fixture() throws -> UpdateFixture {
        let fixture = try UpdateFixture()
        let home = fixture.home
        addTeardownBlock { try FileManager.default.removeItem(at: home) }
        return fixture
    }
}

private final class UpdateFixture {
    let home: URL
    let binary: URL
    let plist: URL
    let directory: URL
    let build: URL
    let source: URL
    let receipt: URL
    let revision = String(repeating: "a", count: 40)
    let oldBinary = Data("old executable bytes".utf8)
    let newBinary = Data("new validated executable bytes".utf8)
    var commands: [UpdateCommand] = []
    var messages: [String] = []
    var loaded = true
    var pid: Int32? = 41
    var requests = 0
    var bootstraps = 0
    var bootouts = 0
    var clock: TimeInterval = 0
    var exitsOnRequest = true
    var binaryAtRequest: Data?
    var failure: String?
    var onBuild: (() throws -> Void)?
    var onExitRequest: (() -> Void)?

    init() throws {
        home = FileManager.default.temporaryDirectory.appendingPathComponent("quill-update-test-\(UUID().uuidString)")
        binary = home.appendingPathComponent("Library/Application Support/quill/bin/quill")
        plist = home.appendingPathComponent("Library/LaunchAgents/com.digimata.quill.plist")
        directory = home.appendingPathComponent("Library/Application Support/quill/updates")
        build = directory.appendingPathComponent("build")
        source = directory.appendingPathComponent("source")
        receipt = directory.appendingPathComponent("installed.json")
        try FileManager.default.createDirectory(at: binary.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: plist.deletingLastPathComponent(), withIntermediateDirectories: true)
        try oldBinary.write(to: binary)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: binary.path)
        let data = try PropertyListSerialization.data(
            fromPropertyList: ["Label": "com.digimata.quill", "ProgramArguments": [binary.path, "run"], "RunAtLoad": true],
            format: .xml, options: 0
        )
        try data.write(to: plist)
    }

    func updater() -> LocalUpdater {
        LocalUpdater(
            home: home, execute: { try self.execute($0) },
            requestExit: { pid in
                XCTAssertEqual(pid, self.pid)
                self.requests += 1
                self.binaryAtRequest = try? Data(contentsOf: self.binary)
                self.onExitRequest?()
                if self.exitsOnRequest { self.pid = nil }
            },
            sleep: { self.clock += $0 }, uptime: { self.clock },
            report: { self.messages.append($0) }
        )
    }

    func writeReceipt(revision: String) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let value = UpdateReceipt(repository: LocalUpdater.repository, revision: revision,
                                  sha256: try LocalUpdater.sha256(binary))
        try JSONEncoder().encode(value).write(to: receipt)
    }

    func onlyBackup() throws -> URL {
        let backups = try FileManager.default.contentsOfDirectory(at: directory.appendingPathComponent("backups"), includingPropertiesForKeys: nil)
        XCTAssertEqual(backups.count, 1)
        return try XCTUnwrap(backups.first)
    }

    private func execute(_ command: UpdateCommand) throws -> UpdateCommand.Result {
        commands.append(command)
        let args = command.arguments
        if command.executable == "/usr/bin/git" {
            switch args.first {
            case "ls-remote":
                return .init(status: 0, output: failure == "malformed remote" ? "not a revision" : "\(revision)\trefs/heads/main\n")
            case "clone":
                try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
            case "remote":
                return .init(status: 0, output: failure == "wrong repository" ? "https://github.com/digimata/quill.git\n" : LocalUpdater.repository + "\n")
            case "status": return .init(status: 0, output: failure == "dirty cache" ? " M Package.swift\n" : "")
            case "rev-parse": return .init(status: 0, output: failure == "wrong checkout" ? String(repeating: "c", count: 40) : revision)
            default: break
            }
        } else if command.executable == "/usr/bin/xcrun" {
            if args.contains("test") {
                if failure == (args.contains("release") ? "release tests" : "debug tests") { return .init(status: 1) }
            }
            if args.contains("build") {
                if args.contains("--show-bin-path") { return .init(status: 0, output: build.path + "\n") }
                if failure == "release build" { return .init(status: 1) }
                try FileManager.default.createDirectory(at: build, withIntermediateDirectories: true)
                let candidate = build.appendingPathComponent("quill")
                try newBinary.write(to: candidate)
                try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: candidate.path)
                try onBuild?()
            }
        } else if command.executable == "/usr/bin/codesign", failure == "signature" {
            return .init(status: 1)
        } else if args == ["update", "--help"], failure == "CLI probe" {
            return .init(status: 1)
        } else if command.executable == "/bin/launchctl" {
            switch args.first {
            case "print":
                if failure == "unknown state after bootstrap", bootstraps > 0 { return .init(status: 1, output: "unavailable") }
                guard loaded else { return .init(status: 113, output: "Could not find service") }
                let program = failure == "different loaded program" ? "/another/quill" : binary.path
                var output = "program = \(program)\nstate = \(pid == nil ? "not running" : "running")\n"
                if failure == "malformed pid" { output += "pid = unknown\n" }
                else if failure == "overflow pid" { output += "pid = 9999999999999999\n" }
                else if let pid, failure != "missing running pid" { output += "pid = \(pid)\n" }
                return .init(status: 0, output: output)
            case "bootout":
                XCTAssertNil(pid, "Never unload a running daemon")
                loaded = false
                bootouts += 1
            case "bootstrap":
                bootstraps += 1
                if failure == "all bootstraps" || (failure == "first bootstrap" && bootstraps == 1) {
                    return .init(status: 5, output: "bootstrap failed")
                }
                loaded = true
                pid = failure == "first startup exits" && bootstraps == 1 ? nil : Int32(100 + bootstraps)
            default: XCTFail("Unexpected launchctl command: \(args)")
            }
        }
        return .init(status: 0)
    }
}
