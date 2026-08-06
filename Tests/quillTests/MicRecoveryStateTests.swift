import XCTest
@testable import quill

final class MicRecoveryStateTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1_000)

    func testLossRecoveryRecordsOneClosedInterruption() {
        var state = MicRecoveryState()
        state.captureLost(at: start)
        XCTAssertEqual(state.health, .reconnecting)

        state.captureResumed(at: start.addingTimeInterval(2.5))

        XCTAssertEqual(state.health, .healthy)
        XCTAssertEqual(state.interruptions, [
            .init(startedAt: start, endedAt: start.addingTimeInterval(2.5)),
        ])
    }

    func testTimeoutKeepsInterruptionOpenAndMarksFailed() {
        var state = MicRecoveryState()
        state.captureLost(at: start)
        state.recoveryTimedOut()

        XCTAssertEqual(state.health, .failed)
        XCTAssertNil(state.interruptions.last?.endedAt)
    }

    func testStaleTimeoutAfterCaptureResumesLeavesHealthHealthy() {
        var state = MicRecoveryState()
        state.captureLost(at: start)
        state.captureResumed(at: start.addingTimeInterval(2.5))
        state.recoveryTimedOut()

        XCTAssertEqual(state.health, .healthy)
    }

    func testRouteChangeRetriesWithoutOpeningASecondGap() {
        var state = MicRecoveryState()
        state.captureLost(at: start)
        state.recoveryTimedOut()
        state.retryRecovery()

        XCTAssertEqual(state.health, .reconnecting)
        XCTAssertEqual(state.interruptions.count, 1)
    }

    func testFinishClosesAnOpenInterruption() {
        var state = MicRecoveryState()
        state.captureLost(at: start)
        state.finish(at: start.addingTimeInterval(10))

        XCTAssertEqual(
            state.interruptions.last?.endedAt,
            start.addingTimeInterval(10)
        )
    }

    func testConversionCapacityAccountsForUpsampling() {
        XCTAssertEqual(
            MicRecorder.convertedFrameCapacity(
                inputFrames: 4_096,
                inputRate: 24_000,
                outputRate: 48_000
            ),
            8_192
        )
    }

    func testSilenceFramesPreserveElapsedTime() {
        XCTAssertEqual(
            MicRecorder.silenceFrameCount(seconds: 2.5, sampleRate: 48_000),
            120_000
        )
    }
}
