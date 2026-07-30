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
}
