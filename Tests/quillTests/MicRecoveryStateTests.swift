import AVFoundation
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

    func testFixedDatePolicyClosesTheOriginalInterruptionAfterFailedRetry() {
        let lostAt = Date(timeIntervalSince1970: 1_000)
        let resumedAt = Date(timeIntervalSince1970: 1_007)
        var state = MicRecoveryState()

        state.captureLost(at: lostAt)
        state.recoveryTimedOut()
        state.retryRecovery()
        state.captureResumed(at: resumedAt)

        XCTAssertEqual(state.health, .healthy)
        XCTAssertEqual(state.interruptions, [
            .init(startedAt: lostAt, endedAt: resumedAt),
        ])
    }

    func testWatchdogTreatsMissingOrStaleBuffersAsCaptureLoss() {
        let startedAt = Date(timeIntervalSince1970: 1_000)
        let now = startedAt.addingTimeInterval(2.1)

        XCTAssertTrue(MicRecorder.captureIsStale(
            startedAt: startedAt,
            lastBufferAt: nil,
            now: now,
            timeout: 2
        ))
        XCTAssertFalse(MicRecorder.captureIsStale(
            startedAt: startedAt,
            lastBufferAt: now.addingTimeInterval(-1),
            now: now,
            timeout: 2
        ))
        XCTAssertTrue(MicRecorder.captureIsStale(
            startedAt: startedAt,
            lastBufferAt: now.addingTimeInterval(-2.1),
            now: now,
            timeout: 2
        ))
    }

    func testFailedRoutePollingRetriesOnlyWhenRouteIdentityChanges() {
        let active = InputDescription(
            name: "AirPods",
            uid: "airpods",
            sampleRate: 24_000,
            channelCount: 1
        )

        XCTAssertFalse(MicRecorder.inputRouteChanged(from: active, to: active))
        XCTAssertTrue(MicRecorder.inputRouteChanged(
            from: active,
            to: .init(name: "AirPods", uid: "airpods", sampleRate: 48_000, channelCount: 1)
        ))
        XCTAssertTrue(MicRecorder.inputRouteChanged(from: nil, to: active))
    }

    func testRecoveredBufferClaimPreventsTimeoutClaim() {
        let claim = RecoveryClaim()

        XCTAssertTrue(claim.claimBuffer())
        XCTAssertFalse(claim.claimTimeout())
    }

    func testTimeoutClaimPreventsRecoveredBufferClaim() {
        let claim = RecoveryClaim()

        XCTAssertTrue(claim.claimTimeout())
        XCTAssertFalse(claim.claimBuffer())
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

    func testConverterUpsamplesAnEntireInputBuffer() throws {
        let inputFormat = try XCTUnwrap(AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 24_000,
            channels: 1,
            interleaved: false
        ))
        let outputFormat = try XCTUnwrap(AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 48_000,
            channels: 1,
            interleaved: false
        ))
        let input = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: inputFormat, frameCapacity: 4_096))
        input.frameLength = 4_096
        input.floatChannelData?[0].update(repeating: 0.25, count: 4_096)
        let output = try XCTUnwrap(AVAudioPCMBuffer(
            pcmFormat: outputFormat,
            frameCapacity: MicRecorder.convertedFrameCapacity(
                inputFrames: input.frameLength,
                inputRate: inputFormat.sampleRate,
                outputRate: outputFormat.sampleRate
            )
        ))
        let converter = try XCTUnwrap(AVAudioConverter(from: inputFormat, to: outputFormat))

        let status = try MicRecorder.convert(input, with: converter, to: output)

        XCTAssertEqual(status, .haveData)
        XCTAssertEqual(output.frameLength, 8_192)
    }

    func testConverterPreservesFractionalFramesWhenReused() throws {
        let inputFormat = try XCTUnwrap(AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 44_100,
            channels: 1,
            interleaved: false
        ))
        let outputFormat = try XCTUnwrap(AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 48_000,
            channels: 1,
            interleaved: false
        ))
        let input = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: inputFormat, frameCapacity: 4_096))
        input.frameLength = 4_096
        let output = try XCTUnwrap(AVAudioPCMBuffer(
            pcmFormat: outputFormat,
            frameCapacity: MicRecorder.convertedFrameCapacity(
                inputFrames: input.frameLength,
                inputRate: inputFormat.sampleRate,
                outputRate: outputFormat.sampleRate
            )
        ))
        let converter = try XCTUnwrap(AVAudioConverter(from: inputFormat, to: outputFormat))

        var convertedFrames = 0
        for _ in 0..<10 {
            _ = try MicRecorder.convert(input, with: converter, to: output)
            convertedFrames += Int(output.frameLength)
        }

        XCTAssertEqual(convertedFrames, 44_582)
    }
}
