import XCTest
@testable import quill

final class RecordingSessionMetadataTests: XCTestCase {
    private let startedAt = Date(timeIntervalSince1970: 1_000)
    private let endedAt = Date(timeIntervalSince1970: 1_010)

    func testHealthyMicrophoneMetadataIsCompleteAndPreservesExistingFields() {
        let micFirstBufferAt = startedAt.addingTimeInterval(1)
        let systemFirstBufferAt = startedAt.addingTimeInterval(0.5)
        let input = InputDescription(
            name: "AirPods",
            uid: "airpods-input",
            sampleRate: 24_000,
            channelCount: 1
        )

        let metadata = RecordingSession.makeMetadata(
            startedAt: startedAt,
            endedAt: endedAt,
            micFirstBufferAt: micFirstBufferAt,
            systemFirstBufferAt: systemFirstBufferAt,
            recoveryState: MicRecoveryState(),
            initialInput: input
        )

        XCTAssertEqual(metadata["files"] as? [String: String], ["mic": "mic.caf", "system": "system.caf"])
        XCTAssertEqual(metadata["start_offset_ms"] as? [String: Int], ["mic": 500, "system": 0])

        let microphone = try! XCTUnwrap(metadata["microphone"] as? [String: Any])
        XCTAssertEqual(microphone["partial"] as? Bool, false)
        XCTAssertEqual(microphone["final_status"] as? String, "healthy")
        let device = try! XCTUnwrap(microphone["initial_device"] as? [String: Any])
        XCTAssertEqual(device["name"] as? String, "AirPods")
        XCTAssertEqual(device["uid"] as? String, "airpods-input")
        XCTAssertEqual(device["sample_rate"] as? Double, 24_000)
        XCTAssertEqual(device["channels"] as? UInt32, 1)
        XCTAssertEqual(microphone["interruptions"] as? [[String: String]], [])
    }

    func testNoMicBufferMarksMetadataPartialAndFailed() {
        let metadata = RecordingSession.makeMetadata(
            startedAt: startedAt,
            endedAt: endedAt,
            micFirstBufferAt: nil,
            systemFirstBufferAt: startedAt.addingTimeInterval(1),
            recoveryState: MicRecoveryState(),
            initialInput: nil
        )

        let microphone = try! XCTUnwrap(metadata["microphone"] as? [String: Any])
        XCTAssertEqual(microphone["partial"] as? Bool, true)
        XCTAssertEqual(microphone["final_status"] as? String, "failed")
        XCTAssertNil(microphone["initial_device"])
    }

    func testReconnectingMicrophoneAtFinalizationIsPartialAndFailed() {
        var recoveryState = MicRecoveryState()
        recoveryState.captureLost(at: startedAt.addingTimeInterval(2))

        let metadata = RecordingSession.makeMetadata(
            startedAt: startedAt,
            endedAt: endedAt,
            micFirstBufferAt: startedAt,
            systemFirstBufferAt: startedAt,
            recoveryState: recoveryState,
            initialInput: nil
        )

        let microphone = try! XCTUnwrap(metadata["microphone"] as? [String: Any])
        XCTAssertEqual(microphone["partial"] as? Bool, true)
        XCTAssertEqual(microphone["final_status"] as? String, "failed")
    }

    func testInterruptionMetadataUsesISO8601Dates() {
        let interruptionStartedAt = startedAt.addingTimeInterval(2)
        let interruptionEndedAt = startedAt.addingTimeInterval(4)
        var recoveryState = MicRecoveryState()
        recoveryState.captureLost(at: interruptionStartedAt)
        recoveryState.captureResumed(at: interruptionEndedAt)

        let metadata = RecordingSession.makeMetadata(
            startedAt: startedAt,
            endedAt: endedAt,
            micFirstBufferAt: startedAt,
            systemFirstBufferAt: startedAt,
            recoveryState: recoveryState,
            initialInput: nil
        )

        let microphone = try! XCTUnwrap(metadata["microphone"] as? [String: Any])
        XCTAssertEqual(microphone["partial"] as? Bool, true,
                       "Recovered capture still contains missing speech")
        XCTAssertEqual(microphone["final_status"] as? String, "healthy",
                       "Final device health is independent of recording completeness")
        XCTAssertEqual(microphone["interruptions"] as? [[String: String]], [[
            "started": "1970-01-01T00:16:42Z",
            "ended": "1970-01-01T00:16:44Z",
        ]])
    }

    func testFailedMetadataSaveCanBeRetriedWithoutChangingEndTimeOrAudio() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let session = try RecordingSession(root: root)
        let audio = session.dir.appendingPathComponent("mic.caf")
        let originalAudio = Data("preserved recording".utf8)
        try originalAudio.write(to: audio)
        let metadata = session.dir.appendingPathComponent("meta.json")
        // A directory at the destination reliably simulates a save failure,
        // including when tests run with permission to bypass file modes.
        try FileManager.default.createDirectory(at: metadata, withIntermediateDirectories: false)

        XCTAssertThrowsError(try session.stop())
        let stoppedAt = try XCTUnwrap(session.endedAt)
        XCTAssertThrowsError(try session.stop())
        XCTAssertEqual(session.endedAt, stoppedAt)

        try FileManager.default.removeItem(at: metadata)
        try session.stop()
        let saved = try Data(contentsOf: metadata)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: saved) as? [String: Any])
        XCTAssertEqual(json["ended"] as? String, ISO8601DateFormatter().string(from: stoppedAt))
        XCTAssertEqual(try Data(contentsOf: audio), originalAudio)
        XCTAssertEqual(session.endedAt, stoppedAt)
        try session.stop()
        XCTAssertEqual(try Data(contentsOf: metadata), saved)
    }
}
