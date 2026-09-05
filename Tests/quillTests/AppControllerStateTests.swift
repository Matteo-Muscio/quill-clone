import XCTest
@testable import quill

final class AppControllerStateTests: XCTestCase {
    func testTranscriptionEndingDoesNotUnlockWhileRecording() {
        var state = AppBusyState()
        state.isRecording = true
        state.isTranscribing = true

        state.isTranscribing = false

        XCTAssertTrue(state.modelActionsLocked)
    }

    func testRecordingEndingDoesNotUnlockWhileTranscribing() {
        var state = AppBusyState()
        state.isTranscribing = true
        state.isRecording = true

        state.isRecording = false

        XCTAssertTrue(state.modelActionsLocked)
    }

    func testModelPreparationOnlyPreventsRecordingStart() {
        var state = AppBusyState()
        state.isPreparingModel = true

        XCTAssertFalse(state.canStartRecording)
        XCTAssertFalse(state.modelActionsLocked)
    }

    func testRecordingHandoffStaysLockedWhenTranscriptionIsEnabled() {
        var state = AppBusyState()
        state.isRecording = true

        state.finishRecording(transcriptionEnabled: true)

        XCTAssertFalse(state.isRecording)
        XCTAssertTrue(state.isTranscribing)
        XCTAssertTrue(state.modelActionsLocked)
    }

    func testRecordingHandoffUnlocksWhenTranscriptionIsDisabled() {
        var state = AppBusyState()
        state.isRecording = true

        state.finishRecording(transcriptionEnabled: false)

        XCTAssertFalse(state.isRecording)
        XCTAssertFalse(state.isTranscribing)
        XCTAssertFalse(state.modelActionsLocked)
    }

    func testRecordingWithFailedMicrophoneShowsFailureIndicatorWithoutEndingRecording() {
        var state = AppBusyState()
        state.isRecording = true
        state.micHealth = .failed

        XCTAssertTrue(state.isRecording)
        XCTAssertEqual(state.recordingIndicator, .microphoneFailed)
    }

    func testHealthyMicrophoneRecoveryRestoresRecordingIndicator() {
        var state = AppBusyState()
        state.isRecording = true
        state.micHealth = .failed

        state.micHealth = .healthy

        XCTAssertEqual(state.recordingIndicator, .recording)
    }

    func testUnsavedRecordingBlocksNewCaptureAndTranscriptionRetryUntilSaved() {
        var state = AppBusyState()
        state.isRecording = true
        state.hasUnsavedRecording = true
        state.finishRecording(transcriptionEnabled: false)

        XCTAssertFalse(state.isRecording)
        XCTAssertFalse(state.isTranscribing)
        XCTAssertFalse(state.canStartRecording)
        XCTAssertFalse(state.canRetryTranscription)
        XCTAssertEqual(state.recordingIndicator, .idle)

        state.hasUnsavedRecording = false
        state.finishRecording(transcriptionEnabled: true)
        XCTAssertTrue(state.canStartRecording)
        XCTAssertTrue(state.isTranscribing)
        XCTAssertTrue(state.modelActionsLocked)
    }

    func testFailedSaveDoesNotUnlockAnEarlierTranscription() {
        var state = AppBusyState()
        state.isRecording = true
        state.isTranscribing = true
        state.hasUnsavedRecording = true

        state.finishRecording(transcriptionEnabled: false)

        XCTAssertTrue(state.isTranscribing)
        XCTAssertTrue(state.modelActionsLocked)
    }

    func testRetryTranscriptionWaitsForModelPreparationAndActiveJob() {
        var state = AppBusyState()
        XCTAssertTrue(state.canRetryTranscription)
        state.isPreparingModel = true
        XCTAssertFalse(state.canRetryTranscription)
        state.isPreparingModel = false
        state.isTranscribing = true
        XCTAssertFalse(state.canRetryTranscription)
        state.isTranscribing = false
        state.isRecording = true
        XCTAssertTrue(state.canRetryTranscription,
                      "Older sessions may transcribe while a new session records")
    }
}
