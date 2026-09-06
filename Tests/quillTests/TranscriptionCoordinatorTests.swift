import Foundation
import XCTest
@testable import quill

final class TranscriptionCoordinatorTests: XCTestCase {
    func testDisabledTranscriptionStillLaunchesStopHookAfterReservation() async throws {
        let root = try temporaryRoot()
        let session = try makeSession("pending", in: root)
        let marker = session.appendingPathComponent("hook-ran")
        let coordinator = TranscriptionCoordinator(
            transcriptionEnabled: { false }, notification: { _, _ in },
            onStop: { #"printf complete > "$0/hook-ran"; :"# }
        )
        let reserved = await coordinator.reserveForUpdate()
        XCTAssertTrue(reserved)
        await coordinator.enqueue(session)
        await waitUntil { FileManager.default.fileExists(atPath: marker.path) }
        XCTAssertEqual(try String(contentsOf: marker, encoding: .utf8), "complete")
    }

    func testUpdateReservationAllowsDurableMissingModelQueueAndRestartRecoversIt() async throws {
        let root = try temporaryRoot()
        let session = try makeSession("pending", in: root)
        let statuses = Locked<[String]>([])
        let coordinator = TranscriptionCoordinator(
            transcriptionEnabled: { true }, isModelInstalled: { _ in false },
            notification: { _, _ in }
        )
        await coordinator.setStatusHandler { status in
            statuses.update { $0.append(Self.label(for: status)) }
        }
        await coordinator.resumePending(root: root)
        await waitUntil { statuses.value.contains("waiting:1") }
        let reserved = await coordinator.reserveForUpdate()
        XCTAssertTrue(reserved)
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: session.appendingPathComponent("meta.json").path
        ))
        let nextLaunch = TranscriptionCoordinator(
            transcriptionEnabled: { true }, isModelInstalled: { _ in true },
            makeEngine: { _ in TestEngine() }, notification: { _, _ in }
        )
        await nextLaunch.resumePending(root: root)
        await waitUntil {
            FileManager.default.fileExists(atPath: session.appendingPathComponent("transcript.json").path)
        }
    }

    func testUpdateReservationRejectsInFlightWorkAndEngineRelease() async throws {
        let root = try temporaryRoot()
        _ = try makeSession("pending", in: root)
        let transcribeGate = TestGate()
        let releaseGate = TestGate()
        let engine = TestEngine(transcribeGate: transcribeGate, releaseGate: releaseGate)
        let statuses = Locked<[String]>([])
        let coordinator = TranscriptionCoordinator(
            transcriptionEnabled: { true }, isModelInstalled: { _ in true },
            makeEngine: { _ in engine }, notification: { _, _ in }
        )
        await coordinator.setStatusHandler { status in
            statuses.update { $0.append(Self.label(for: status)) }
        }
        await coordinator.resumePending(root: root)
        await transcribeGate.waitUntilEntered()
        let duringTranscription = await coordinator.reserveForUpdate()
        XCTAssertFalse(duringTranscription)
        await transcribeGate.open()
        await releaseGate.waitUntilEntered()
        let duringRelease = await coordinator.reserveForUpdate()
        XCTAssertFalse(duringRelease)
        await releaseGate.open()
        await waitUntil { statuses.value.last == "idle" }
        let afterRelease = await coordinator.reserveForUpdate()
        XCTAssertTrue(afterRelease)
    }

    func testReservedCoordinatorDefersNewWorkToRestartWithoutDeletingIt() async throws {
        let root = try temporaryRoot()
        let session = try makeSession("pending", in: root)
        let engine = TestEngine()
        let coordinator = TranscriptionCoordinator(
            transcriptionEnabled: { true }, isModelInstalled: { _ in true },
            makeEngine: { _ in engine }, notification: { _, _ in }
        )
        let reserved = await coordinator.reserveForUpdate()
        XCTAssertTrue(reserved)
        let duplicate = await coordinator.reserveForUpdate()
        XCTAssertFalse(duplicate)
        await coordinator.enqueue(session)
        await coordinator.resumePending(root: root)
        await coordinator.modelDidActivate(root: root)
        for _ in 0..<20 { await Task.yield() }
        let count = await engine.transcribeCount
        XCTAssertEqual(count, 0)
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: session.appendingPathComponent("meta.json").path
        ))
        let nextLaunch = TranscriptionCoordinator(
            transcriptionEnabled: { true }, isModelInstalled: { _ in true },
            makeEngine: { _ in engine }, notification: { _, _ in }
        )
        await nextLaunch.resumePending(root: root)
        await waitUntil {
            FileManager.default.fileExists(atPath: session.appendingPathComponent("transcript.json").path)
        }
    }

    func testMissingModelRetainsQueueAndPublishesWaitingOnce() async throws {
        let root = try temporaryRoot()
        let session = try makeSession("2026-07-30-100000", in: root)
        let installed = Locked(false)
        let probes = Locked(0)
        let engine = TestEngine()
        let statuses = Locked<[String]>([])
        let notifications = Locked<[String]>([])
        let coordinator = TranscriptionCoordinator(
            transcriptionEnabled: { true },
            selectedModel: { .parakeetV3 },
            isModelInstalled: { _ in
                probes.update { $0 += 1 }
                return installed.value
            },
            makeEngine: { _ in engine },
            notification: { title, _ in notifications.update { $0.append(title) } }
        )
        await coordinator.setStatusHandler { status in
            statuses.update { $0.append(Self.label(for: status)) }
        }

        await coordinator.resumePending(root: root)
        await waitUntil { statuses.value.contains("waiting:1") }

        XCTAssertFalse(FileManager.default.fileExists(
            atPath: session.appendingPathComponent("transcript.json").path
        ))
        let prepareCount = await engine.prepareCount
        XCTAssertEqual(prepareCount, 0)
        XCTAssertEqual(notifications.value, ["quill — transcription waiting"])

        await coordinator.resumePending(root: root)
        await waitUntil { probes.value >= 2 }
        await coordinator.resumePending(root: root)
        await waitUntil { probes.value >= 3 }

        XCTAssertEqual(statuses.value.filter { $0 == "waiting:1" }.count, 1)
        XCTAssertEqual(notifications.value, ["quill — transcription waiting"])
        XCTAssertFalse(statuses.value.contains { $0.hasPrefix("failed:") })
    }

    func testActivationRescansAndDrainsRetainedSessionWithoutDuplicates() async throws {
        let root = try temporaryRoot()
        let session = try makeSession("2026-07-30-100000", in: root)
        let installed = Locked(false)
        let engine = TestEngine()
        let statuses = Locked<[String]>([])
        let coordinator = TranscriptionCoordinator(
            transcriptionEnabled: { true },
            selectedModel: { .parakeetV3 },
            isModelInstalled: { _ in installed.value },
            makeEngine: { _ in engine },
            notification: { _, _ in }
        )
        await coordinator.setStatusHandler { status in
            statuses.update { $0.append(Self.label(for: status)) }
        }

        await coordinator.resumePending(root: root)
        await waitUntil { statuses.value.contains("waiting:1") }
        await coordinator.resumePending(root: root)
        installed.set(true)

        await coordinator.modelDidActivate(root: root)
        await waitUntil {
            FileManager.default.fileExists(
                atPath: session.appendingPathComponent("transcript.json").path
            )
        }
        await coordinator.modelDidActivate(root: root)
        for _ in 0..<20 { await Task.yield() }

        let transcribeCount = await engine.transcribeCount
        XCTAssertEqual(transcribeCount, 1)
        XCTAssertEqual(statuses.value.filter { $0 == "waiting:1" }.count, 1)
        XCTAssertEqual(statuses.value.filter { $0.hasPrefix("transcribing:") }.count, 1)
    }

    func testRestartRecoveryContinuesAfterFailedSession() async throws {
        let root = try temporaryRoot()
        let failed = root.appendingPathComponent("2026-07-30-100000", isDirectory: true)
        try FileManager.default.createDirectory(at: failed, withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: failed.appendingPathComponent("meta.json"))
        let successful = try makeSession("2026-07-30-100001", in: root)
        let engine = TestEngine()
        let statuses = Locked<[String]>([])
        let coordinator = TranscriptionCoordinator(
            transcriptionEnabled: { true },
            selectedModel: { .parakeetV3 },
            isModelInstalled: { _ in true },
            makeEngine: { _ in engine },
            notification: { _, _ in }
        )
        await coordinator.setStatusHandler { status in
            statuses.update { $0.append(Self.label(for: status)) }
        }

        await coordinator.resumePending(root: root)
        await waitUntil {
            statuses.value.contains("failed:\(failed.lastPathComponent)")
        }

        XCTAssertTrue(FileManager.default.fileExists(
            atPath: failed.appendingPathComponent("transcribe.log").path
        ))
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: successful.appendingPathComponent("transcript.json").path
        ))
        let transcribeCount = await engine.transcribeCount
        XCTAssertEqual(transcribeCount, 1)
    }

    func testRescanDoesNotRequeueInFlightSession() async throws {
        let root = try temporaryRoot()
        _ = try makeSession("2026-07-30-100000", in: root)
        let gate = TestGate()
        let engine = TestEngine(
            model: TranscriptionModel.parakeetV3.provenance,
            transcribeGate: gate
        )
        let statuses = Locked<[String]>([])
        let coordinator = TranscriptionCoordinator(
            transcriptionEnabled: { true },
            selectedModel: { .parakeetV3 },
            isModelInstalled: { _ in true },
            makeEngine: { _ in engine },
            notification: { _, _ in }
        )
        await coordinator.setStatusHandler { status in
            statuses.update { $0.append(Self.label(for: status)) }
        }

        await coordinator.resumePending(root: root)
        await gate.waitUntilEntered()
        await coordinator.modelDidActivate(root: root)
        await gate.open()
        await waitUntil { statuses.value.last == "idle" }

        let transcribeCount = await engine.transcribeCount
        XCTAssertEqual(transcribeCount, 1)
    }

    func testWaitingPublishesChangedPendingCountWithoutRenotifying() async throws {
        let root = try temporaryRoot()
        _ = try makeSession("2026-07-30-100000", in: root)
        let probes = Locked(0)
        let statuses = Locked<[String]>([])
        let notifications = Locked(0)
        let coordinator = TranscriptionCoordinator(
            transcriptionEnabled: { true },
            selectedModel: { .parakeetV3 },
            isModelInstalled: { _ in
                probes.update { $0 += 1 }
                return false
            },
            makeEngine: { _ in TestEngine() },
            notification: { _, _ in notifications.update { $0 += 1 } }
        )
        await coordinator.setStatusHandler { status in
            statuses.update { $0.append(Self.label(for: status)) }
        }

        await coordinator.resumePending(root: root)
        await waitUntil { statuses.value.contains("waiting:1") }
        _ = try makeSession("2026-07-30-100001", in: root)
        await coordinator.resumePending(root: root)
        await waitUntil { probes.value >= 2 }

        XCTAssertEqual(statuses.value.filter { $0.hasPrefix("waiting:") }, [
            "waiting:1",
            "waiting:2",
        ])
        XCTAssertEqual(notifications.value, 1)
    }

    func testFailedReplacementPrepareDoesNotReuseReleasedEngine() async throws {
        let root = try temporaryRoot()
        _ = try makeSession("2026-07-30-100000", in: root)
        let failed = try makeSession("2026-07-30-100001", in: root)
        _ = try makeSession("2026-07-30-100002", in: root)
        let selections = Locked([
            TranscriptionModel.parakeetV3,
            .parakeetV3,
            .parakeetV2,
            .parakeetV2,
            .parakeetV3,
            .parakeetV3,
        ])
        let v3FactoryCalls = Locked(0)
        let firstV3 = TestEngine(model: TranscriptionModel.parakeetV3.provenance)
        let secondV3 = TestEngine(model: TranscriptionModel.parakeetV3.provenance)
        let v2 = TestEngine(
            model: TranscriptionModel.parakeetV2.provenance,
            prepareFails: true
        )
        let statuses = Locked<[String]>([])
        let coordinator = TranscriptionCoordinator(
            transcriptionEnabled: { true },
            selectedModel: { selections.update { $0.removeFirst() } },
            isModelInstalled: { _ in true },
            makeEngine: { model in
                guard model == .parakeetV3 else { return v2 }
                return v3FactoryCalls.update {
                    $0 += 1
                    return $0 == 1 ? firstV3 : secondV3
                }
            },
            notification: { _, _ in }
        )
        await coordinator.setStatusHandler { status in
            statuses.update { $0.append(Self.label(for: status)) }
        }

        await coordinator.resumePending(root: root)
        await waitUntil {
            statuses.value.contains("failed:\(failed.lastPathComponent)")
        }

        XCTAssertEqual(v3FactoryCalls.value, 2)
        let firstReleaseCount = await firstV3.releaseCount
        let secondPrepareCount = await secondV3.prepareCount
        let secondTranscribeCount = await secondV3.transcribeCount
        XCTAssertEqual(firstReleaseCount, 1)
        XCTAssertEqual(secondPrepareCount, 1)
        XCTAssertEqual(secondTranscribeCount, 1)
    }

    func testSelectionChangeDuringProbeReprobesBeforeDequeuing() async throws {
        let root = try temporaryRoot()
        let session = try makeSession("2026-07-30-100000", in: root)
        let selection = Locked(TranscriptionModel.parakeetV3)
        let probeGate = TestGate()
        let probedModels = Locked<[TranscriptionModel]>([])
        let factoryModels = Locked<[TranscriptionModel]>([])
        let v2 = TestEngine(model: TranscriptionModel.parakeetV2.provenance)
        let v3 = TestEngine(model: TranscriptionModel.parakeetV3.provenance)
        let coordinator = TranscriptionCoordinator(
            transcriptionEnabled: { true },
            selectedModel: { selection.value },
            isModelInstalled: { model in
                let isFirst = probedModels.update {
                    $0.append(model)
                    return $0.count == 1
                }
                if isFirst {
                    await probeGate.wait()
                }
                return true
            },
            makeEngine: { model in
                factoryModels.update { $0.append(model) }
                return model == .parakeetV2 ? v2 : v3
            },
            notification: { _, _ in }
        )

        await coordinator.resumePending(root: root)
        await probeGate.waitUntilEntered()
        selection.set(.parakeetV2)
        await probeGate.open()
        await waitUntil {
            FileManager.default.fileExists(
                atPath: session.appendingPathComponent("transcript.json").path
            )
        }

        XCTAssertEqual(probedModels.value, [.parakeetV3, .parakeetV2])
        XCTAssertEqual(factoryModels.value, [.parakeetV2])
        let v2TranscribeCount = await v2.transcribeCount
        let v3TranscribeCount = await v3.transcribeCount
        XCTAssertEqual(v2TranscribeCount, 1)
        XCTAssertEqual(v3TranscribeCount, 0)
    }

    func testEnqueueDuringEngineReleaseDrainsWithoutAnotherTrigger() async throws {
        let root = try temporaryRoot()
        let first = try makeSession("2026-07-30-100000", in: root)
        let releaseGate = TestGate()
        let engine = TestEngine(
            model: TranscriptionModel.parakeetV3.provenance,
            releaseGate: releaseGate
        )
        let coordinator = TranscriptionCoordinator(
            transcriptionEnabled: { true },
            selectedModel: { .parakeetV3 },
            isModelInstalled: { _ in true },
            makeEngine: { _ in engine },
            notification: { _, _ in }
        )

        await coordinator.enqueue(first)
        await releaseGate.waitUntilEntered()
        let second = try makeSession("2026-07-30-100001", in: root)
        await coordinator.enqueue(second)
        await releaseGate.open()
        await waitUntil {
            FileManager.default.fileExists(
                atPath: second.appendingPathComponent("transcript.json").path
            )
        }

        let transcribeCount = await engine.transcribeCount
        XCTAssertEqual(transcribeCount, 2)
    }

    func testPartialMicrophoneSessionSurfacesWarningInTranscriptAndNotification() async throws {
        let root = try temporaryRoot()
        let session = try makeSession("2026-07-30-100000", in: root, microphonePartial: true)
        let notifications = Locked<[(String, String)]>([])
        let coordinator = TranscriptionCoordinator(
            transcriptionEnabled: { true },
            selectedModel: { .parakeetV3 },
            isModelInstalled: { _ in true },
            makeEngine: { _ in TestEngine() },
            notification: { title, body in notifications.update { $0.append((title, body)) } }
        )

        await coordinator.enqueue(session)
        await waitUntil {
            FileManager.default.fileExists(
                atPath: session.appendingPathComponent("transcript.json").path
            )
        }

        XCTAssertEqual(notifications.value.count, 1)
        XCTAssertEqual(notifications.value.first?.0, "quill — transcript ready")
        XCTAssertEqual(
            notifications.value.first?.1,
            "2026-07-30-100000 — microphone audio is incomplete"
        )
        let transcriptData = try Data(contentsOf: session.appendingPathComponent("transcript.json"))
        let transcript = try XCTUnwrap(
            JSONSerialization.jsonObject(with: transcriptData) as? [String: Any]
        )
        XCTAssertEqual(transcript["partial"] as? Bool, true)
        let markdown = try String(
            contentsOf: session.appendingPathComponent("transcript.md"), encoding: .utf8
        )
        XCTAssertTrue(markdown.contains(
            "microphone capture was incomplete and some of the user's speech may be missing"
        ))
    }

    func testLegacyRecoveredMicrophoneInterruptionStillWarns() async throws {
        let root = try temporaryRoot()
        let session = try makeSession("legacy-interruption", in: root)
        try Data(#"{"files":{"mic":"mic.caf"},"microphone":{"partial":false,"health":"healthy","interruptions":[{"cause":"route_change"}]}}"#.utf8)
            .write(to: session.appendingPathComponent("meta.json"))
        let (coordinator, statuses, notifications) = coordinator(using: TestEngine())
        await coordinator.setStatusHandler { status in
            statuses.update { $0.append(Self.label(for: status)) }
        }
        await coordinator.enqueue(session)
        await waitUntil { statuses.value.last == "idle" }
        XCTAssertEqual(try readTranscript(session)["partial"] as? Bool, true)
        XCTAssertEqual(notifications.value.last?.1, "legacy-interruption — microphone audio is incomplete")
        let markdown = try String(contentsOf: session.appendingPathComponent("transcript.md"), encoding: .utf8)
        XCTAssertTrue(markdown.contains("microphone capture was incomplete"))
    }

    func testOneFailedTrackPreservesOtherSpeechAndMarksPartial() async throws {
        let root = try temporaryRoot()
        let session = try makeSession("one-failed", in: root)
        try addSystemTrack(to: session)
        let engine = TestEngine(failedFiles: ["mic.caf"])
        let (coordinator, statuses, notifications) = coordinator(using: engine)
        await coordinator.setStatusHandler { status in
            statuses.update { $0.append(Self.label(for: status)) }
        }
        await coordinator.enqueue(session)
        await waitUntil { statuses.value.last == "idle" }

        let transcript = try readTranscript(session)
        XCTAssertEqual(transcript["partial"] as? Bool, true)
        let segments = try XCTUnwrap(transcript["segments"] as? [[String: Any]])
        XCTAssertEqual(segments.count, 1)
        XCTAssertEqual(segments.first?["text"] as? String, "system.caf")
        XCTAssertEqual(segments.first?["speaker"] as? String, "them")
        let markdown = try String(contentsOf: session.appendingPathComponent("transcript.md"), encoding: .utf8)
        XCTAssertTrue(markdown.contains("audio could not be transcribed from: mic.caf"))
        XCTAssertEqual(notifications.value.last?.1, "one-failed — audio is incomplete")
    }

    func testMissingDeclaredTrackMarksPartialWithoutLosingGoodTrack() async throws {
        let root = try temporaryRoot()
        let session = try makeSession("missing-track", in: root)
        try addSystemTrack(to: session, createAudio: false)
        let engine = TestEngine()
        let (coordinator, statuses, _) = coordinator(using: engine)
        await coordinator.setStatusHandler { status in
            statuses.update { $0.append(Self.label(for: status)) }
        }
        await coordinator.enqueue(session)
        await waitUntil { statuses.value.last == "idle" }
        let transcript = try readTranscript(session)
        XCTAssertEqual(transcript["partial"] as? Bool, true)
        XCTAssertEqual((transcript["segments"] as? [[String: Any]])?.count, 1)
        XCTAssertTrue((transcript["warning"] as? String)?.contains("system.caf") == true)
        let count = await engine.transcribeCount
        XCTAssertEqual(count, 1)
    }

    func testAllTracksFailRemainPendingAndCanRetrySuccessfully() async throws {
        let root = try temporaryRoot()
        let session = try makeSession("all-failed", in: root)
        try addSystemTrack(to: session)
        let engine = TestEngine(failedFiles: ["mic.caf", "system.caf"])
        let (coordinator, statuses, notifications) = coordinator(using: engine)
        await coordinator.setStatusHandler { status in
            statuses.update { $0.append(Self.label(for: status)) }
        }
        await coordinator.enqueue(session)
        await waitUntil { statuses.value.last == "failed:all-failed" }
        XCTAssertFalse(FileManager.default.fileExists(atPath: session.appendingPathComponent("transcript.json").path))
        XCTAssertEqual(notifications.value.last?.0, "quill — transcription failed")

        await engine.allowAllTracks()
        await coordinator.resumePending(root: root)
        await waitUntil { statuses.value.last == "idle" }
        XCTAssertEqual((try readTranscript(session)["segments"] as? [[String: Any]])?.count, 2)
    }

    func testAllMissingAndUnsupportedTracksNeverPublishCompletion() async throws {
        let root = try temporaryRoot()
        let missing = try makeSession("all-missing", in: root)
        try FileManager.default.removeItem(at: missing.appendingPathComponent("mic.caf"))
        let unsupported = try makeSession("unsupported", in: root)
        try Data(#"{"files":{"other":"other.caf"}}"#.utf8)
            .write(to: unsupported.appendingPathComponent("meta.json"))
        let engine = TestEngine()
        let (coordinator, statuses, notifications) = coordinator(using: engine)
        await coordinator.setStatusHandler { status in
            statuses.update { $0.append(Self.label(for: status)) }
        }
        await coordinator.resumePending(root: root)
        await waitUntil { statuses.value.last == "failed:unsupported" }
        for session in [missing, unsupported] {
            XCTAssertFalse(FileManager.default.fileExists(atPath: session.appendingPathComponent("transcript.json").path))
        }
        XCTAssertEqual(notifications.value.filter { $0.0 == "quill — transcription failed" }.count, 2)
        let count = await engine.transcribeCount
        XCTAssertEqual(count, 0)
    }

    func testSuccessfulSilentTrackIsACompleteEmptyTranscript() async throws {
        let root = try temporaryRoot()
        let session = try makeSession("silent", in: root)
        let (coordinator, statuses, _) = coordinator(using: TestEngine(emptySpeech: true))
        await coordinator.setStatusHandler { status in
            statuses.update { $0.append(Self.label(for: status)) }
        }
        await coordinator.enqueue(session)
        await waitUntil { statuses.value.last == "idle" }
        let transcript = try readTranscript(session)
        XCTAssertEqual(transcript["partial"] as? Bool, false)
        XCTAssertEqual((transcript["segments"] as? [[String: Any]])?.count, 0)
    }

    func testMarkdownWriteFailureDoesNotPublishJSONAndRetryRepairsPair() async throws {
        let root = try temporaryRoot()
        let session = try makeSession("write-failed", in: root)
        let markdown = session.appendingPathComponent("transcript.md")
        try FileManager.default.createDirectory(at: markdown, withIntermediateDirectories: false)
        let (coordinator, statuses, notifications) = coordinator(using: TestEngine())
        await coordinator.setStatusHandler { status in
            statuses.update { $0.append(Self.label(for: status)) }
        }
        await coordinator.enqueue(session)
        await waitUntil { statuses.value.last == "failed:write-failed" }
        XCTAssertFalse(FileManager.default.fileExists(atPath: session.appendingPathComponent("transcript.json").path))
        XCTAssertEqual(notifications.value.last?.0, "quill — transcription failed")
        try FileManager.default.removeItem(at: markdown)
        await coordinator.resumePending(root: root)
        await waitUntil { statuses.value.last == "idle" }
        XCTAssertNoThrow(try readTranscript(session))
        XCTAssertTrue(try String(contentsOf: markdown, encoding: .utf8).contains("mic.caf"))
    }

    func testJSONWriteFailureLeavesReadableOutputAndCanRetry() async throws {
        let root = try temporaryRoot()
        let session = try makeSession("json-failed", in: root)
        let canonical = session.appendingPathComponent("transcript.json")
        try FileManager.default.createDirectory(at: canonical, withIntermediateDirectories: false)
        let (coordinator, statuses, _) = coordinator(using: TestEngine())
        await coordinator.setStatusHandler { status in
            statuses.update { $0.append(Self.label(for: status)) }
        }
        await coordinator.enqueue(session)
        await waitUntil { statuses.value.last == "failed:json-failed" }
        XCTAssertTrue(FileManager.default.fileExists(atPath: session.appendingPathComponent("transcript.md").path))
        XCTAssertThrowsError(try readTranscript(session))
        try FileManager.default.removeItem(at: canonical)
        await coordinator.resumePending(root: root)
        await waitUntil { statuses.value.last == "idle" }
        XCTAssertNoThrow(try readTranscript(session))
    }

    func testLegacyCanonicalRepairsMarkdownWithoutInferenceOrModel() async throws {
        let root = try temporaryRoot()
        let session = try makeSession("legacy", in: root)
        let canonical = session.appendingPathComponent("transcript.json")
        let original = Data(#"{"engine":"legacy","model":"old","created_at":"then","segments":[{"speaker":"me","start_ms":0,"end_ms":1000,"text":"saved speech"}]}"#.utf8)
        try original.write(to: canonical)
        let probes = Locked(0)
        let coordinator = TranscriptionCoordinator(
            transcriptionEnabled: { true },
            isModelInstalled: { _ in probes.update { $0 += 1 }; return false },
            makeEngine: { _ in TestEngine() },
            notification: { _, _ in }
        )
        await coordinator.resumePending(root: root)
        XCTAssertTrue(try String(contentsOf: session.appendingPathComponent("transcript.md"), encoding: .utf8).contains("saved speech"))
        XCTAssertEqual(try Data(contentsOf: canonical), original)
        XCTAssertEqual(probes.value, 0)
        await coordinator.enqueue(session)
        XCTAssertEqual(try Data(contentsOf: canonical), original)
    }

    func testLegacyRepairFailureIsSurfacedAndRetryDoesNotRunInference() async throws {
        let root = try temporaryRoot()
        let session = try makeSession("repair-failed", in: root)
        let canonical = session.appendingPathComponent("transcript.json")
        let original = Data(#"{"engine":"legacy","model":"old","created_at":"then","partial":true,"segments":[]}"#.utf8)
        try original.write(to: canonical)
        let markdown = session.appendingPathComponent("transcript.md")
        try FileManager.default.createDirectory(at: markdown, withIntermediateDirectories: false)
        let engine = TestEngine()
        let (coordinator, statuses, notifications) = coordinator(using: engine)
        await coordinator.setStatusHandler { status in
            statuses.update { $0.append(Self.label(for: status)) }
        }
        await coordinator.resumePending(root: root)
        XCTAssertEqual(statuses.value.last, "failed:repair-failed")
        XCTAssertEqual(notifications.value.last?.0, "quill — transcription failed")
        XCTAssertEqual(try Data(contentsOf: canonical), original)
        try FileManager.default.removeItem(at: markdown)
        await coordinator.resumePending(root: root)
        XCTAssertEqual(statuses.value.last, "idle")
        XCTAssertTrue(try String(contentsOf: markdown, encoding: .utf8).contains("Warning:"))
        XCTAssertEqual(try Data(contentsOf: canonical), original)
        let count = await engine.transcribeCount
        XCTAssertEqual(count, 0)
    }

    func testLegacyRepairFailureRemainsVisibleAfterSuccessfulQueuedSession() async throws {
        let root = try temporaryRoot()
        let failed = try makeUnrepairableLegacySession("a-repair-failed", in: root)
        let good = try makeSession("b-good", in: root)
        let (coordinator, statuses, _) = coordinator(using: TestEngine())
        await coordinator.setStatusHandler { status in
            statuses.update { $0.append(Self.label(for: status)) }
        }
        await coordinator.resumePending(root: root)
        await waitUntil { statuses.value.last == "failed:a-repair-failed" }
        XCTAssertNoThrow(try readTranscript(good))
        XCTAssertTrue(FileManager.default.fileExists(atPath: failed.appendingPathComponent("transcribe.log").path))
        XCTAssertFalse(statuses.value.contains("idle"))
    }

    func testRepairFailureDuringActiveTranscriptionPreservesBusyStatus() async throws {
        let root = try temporaryRoot()
        let good = try makeSession("active", in: root)
        let gate = TestGate()
        let engine = TestEngine(transcribeGate: gate)
        let (coordinator, statuses, notifications) = coordinator(using: engine)
        await coordinator.setStatusHandler { status in
            statuses.update { $0.append(Self.label(for: status)) }
        }
        await coordinator.enqueue(good)
        await gate.waitUntilEntered()
        _ = try makeUnrepairableLegacySession("repair-failed", in: root)
        await coordinator.resumePending(root: root)
        XCTAssertEqual(statuses.value.last, "transcribing:active:0")
        XCTAssertEqual(notifications.value.last?.0, "quill — transcription failed")
        await gate.open()
        await waitUntil { statuses.value.last == "failed:repair-failed" }
        XCTAssertNoThrow(try readTranscript(good))
        XCTAssertFalse(statuses.value.contains("idle"))
    }

    private func makeUnrepairableLegacySession(_ name: String, in root: URL) throws -> URL {
        let session = try makeSession(name, in: root)
        try Data(#"{"engine":"legacy","model":"old","created_at":"then","segments":[]}"#.utf8)
            .write(to: session.appendingPathComponent("transcript.json"))
        try FileManager.default.createDirectory(
            at: session.appendingPathComponent("transcript.md"), withIntermediateDirectories: false
        )
        return session
    }

    func testMalformedCanonicalIsRetried() async throws {
        let root = try temporaryRoot()
        let session = try makeSession("malformed", in: root)
        try Data("{}".utf8).write(to: session.appendingPathComponent("transcript.json"))
        let engine = TestEngine()
        let (coordinator, statuses, _) = coordinator(using: engine)
        await coordinator.setStatusHandler { status in
            statuses.update { $0.append(Self.label(for: status)) }
        }
        await coordinator.resumePending(root: root)
        await waitUntil { statuses.value.last == "idle" }
        XCTAssertEqual(try readTranscript(session)["engine"] as? String, "test")
        let count = await engine.transcribeCount
        XCTAssertEqual(count, 1)
    }

    func testExplicitEnqueueDeduplicatesQueuedInFlightAndCompleteSessions() async throws {
        let root = try temporaryRoot()
        let session = try makeSession("deduplicated", in: root)
        let gate = TestGate()
        let installed = Locked(false)
        let engine = TestEngine(transcribeGate: gate)
        let statuses = Locked<[String]>([])
        let coordinator = TranscriptionCoordinator(
            transcriptionEnabled: { true },
            isModelInstalled: { _ in installed.value },
            makeEngine: { _ in engine }, notification: { _, _ in }
        )
        await coordinator.setStatusHandler { status in
            statuses.update { $0.append(Self.label(for: status)) }
        }
        await coordinator.enqueue(session)
        await waitUntil { statuses.value.last == "waiting:1" }
        await coordinator.enqueue(session)
        await coordinator.resumePending(root: root)
        installed.set(true)
        await coordinator.resumePending(root: root)
        await gate.waitUntilEntered()
        await coordinator.enqueue(session)
        await coordinator.resumePending(root: root)
        await gate.open()
        await waitUntil { statuses.value.last == "idle" }
        let original = try Data(contentsOf: session.appendingPathComponent("transcript.json"))
        await coordinator.enqueue(session)
        await coordinator.resumePending(root: root)
        let count = await engine.transcribeCount
        XCTAssertEqual(count, 1)
        XCTAssertEqual(try Data(contentsOf: session.appendingPathComponent("transcript.json")), original)
    }

    private func coordinator(using engine: TestEngine) -> (
        TranscriptionCoordinator, Locked<[String]>, Locked<[(String, String)]>
    ) {
        let statuses = Locked<[String]>([])
        let notifications = Locked<[(String, String)]>([])
        let coordinator = TranscriptionCoordinator(
            transcriptionEnabled: { true }, selectedModel: { .parakeetV3 },
            isModelInstalled: { _ in true }, makeEngine: { _ in engine },
            notification: { title, body in notifications.update { $0.append((title, body)) } }
        )
        return (coordinator, statuses, notifications)
    }

    private func addSystemTrack(to session: URL, createAudio: Bool = true) throws {
        try Data(#"{"files":{"mic":"mic.caf","system":"system.caf"}}"#.utf8)
            .write(to: session.appendingPathComponent("meta.json"))
        if createAudio { try Data([1]).write(to: session.appendingPathComponent("system.caf")) }
    }

    private func readTranscript(_ session: URL) throws -> [String: Any] {
        let data = try Data(contentsOf: session.appendingPathComponent("transcript.json"))
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private static func label(for status: TranscriptionCoordinator.Status) -> String {
        switch status {
        case .idle:
            "idle"
        case .transcribing(let session, let queued):
            "transcribing:\(session):\(queued)"
        case .failed(let session):
            "failed:\(session)"
        case .waitingForModel(let pending):
            "waiting:\(pending)"
        }
    }

    private func temporaryRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root
    }

    private func makeSession(
        _ name: String,
        in root: URL,
        microphonePartial: Bool = false
    ) throws -> URL {
        let session = root.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: session, withIntermediateDirectories: true)
        let meta: [String: Any] = [
            "files": ["mic": "mic.caf"],
            "microphone": ["partial": microphonePartial],
        ]
        let data = try JSONSerialization.data(withJSONObject: meta)
        try data.write(to: session.appendingPathComponent("meta.json"))
        try Data([1]).write(to: session.appendingPathComponent("mic.caf"))
        return session
    }

    private func waitUntil(
        timeout: Duration = .seconds(2),
        _ condition: @escaping @Sendable () -> Bool
    ) async {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while clock.now < deadline {
            if condition() { return }
            try? await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("condition was not met before timeout")
    }
}

private actor TestEngine: TranscriptionEngine {
    nonisolated let name = "test"
    nonisolated let model: String

    private(set) var prepareCount = 0
    private(set) var transcribeCount = 0
    private(set) var releaseCount = 0
    private let prepareFails: Bool
    private var failedFiles: Set<String>
    private let emptySpeech: Bool
    private let transcribeGate: TestGate?
    private let releaseGate: TestGate?

    init(
        model: String = "test-model",
        prepareFails: Bool = false,
        failedFiles: Set<String> = [],
        emptySpeech: Bool = false,
        transcribeGate: TestGate? = nil,
        releaseGate: TestGate? = nil
    ) {
        self.model = model
        self.prepareFails = prepareFails
        self.failedFiles = failedFiles
        self.emptySpeech = emptySpeech
        self.transcribeGate = transcribeGate
        self.releaseGate = releaseGate
    }

    func prepare() throws {
        prepareCount += 1
        if prepareFails {
            throw TestError.expected
        }
    }

    func allowAllTracks() { failedFiles = [] }

    func transcribe(_ audio: URL) async throws -> [TranscriptSegment] {
        transcribeCount += 1
        await transcribeGate?.wait()
        if failedFiles.contains(audio.lastPathComponent) { throw TestError.expected }
        if emptySpeech { return [] }
        return [TranscriptSegment(start: 0, end: 1, text: audio.lastPathComponent)]
    }

    func release() async {
        releaseCount += 1
        await releaseGate?.wait()
    }
}

private enum TestError: Error {
    case expected
}

private actor TestGate {
    private var entered = false
    private var isOpen = false
    private var continuation: CheckedContinuation<Void, Never>?

    func wait() async {
        entered = true
        guard !isOpen else { return }
        await withCheckedContinuation { continuation = $0 }
    }

    func waitUntilEntered() async {
        while !entered {
            await Task.yield()
        }
    }

    func open() {
        isOpen = true
        continuation?.resume()
        continuation = nil
    }
}

private final class Locked<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Value

    init(_ value: Value) {
        stored = value
    }

    var value: Value {
        lock.withLock { stored }
    }

    func set(_ value: Value) {
        lock.withLock { stored = value }
    }

    func update<Result>(_ body: (inout Value) -> Result) -> Result {
        lock.withLock { body(&stored) }
    }
}
