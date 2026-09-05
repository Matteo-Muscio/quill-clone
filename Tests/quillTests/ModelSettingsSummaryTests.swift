import AppKit
import SwiftUI
import XCTest
@testable import quill

final class ModelSettingsSummaryTests: XCTestCase {
    func testSelectedButUnavailableModelDoesNotClaimReadiness() {
        for state in [ModelState.notInstalled, .installed, .failed("offline"), .activationFailed("read only")] {
            XCTAssertEqual(summary(state: state).title, "Set up transcription")
        }
        XCTAssertEqual(summary(state: .active).title, "Ready to transcribe")
    }

    func testReadinessNamesTheActualActiveModel() {
        let value = ModelSettingsSummary(
            activeModel: .parakeetV2, activeState: .active, isPreparing: false,
            actionsLocked: false, pendingCount: 0, transcriptionEnabled: true
        )
        XCTAssertTrue(value.detail.contains(TranscriptionModel.parakeetV2.displayName))
        XCTAssertFalse(value.detail.contains(TranscriptionModel.parakeetV3.displayName))
    }

    func testPendingRecordingsExplainAutomaticResume() {
        XCTAssertEqual(summary(pending: 1).title, "1 recording waiting")
        XCTAssertEqual(summary(pending: 3).title, "3 recordings waiting")
        XCTAssertTrue(summary(pending: 3).detail.contains("resume automatically"))
    }

    func testPreparationExplainsRecordingLockBeforePendingSetup() {
        let value = summary(preparing: true, locked: true, pending: 3)
        XCTAssertEqual(value.title, "Preparing a model")
        XCTAssertTrue(value.detail.contains("Recording is unavailable"))
        XCTAssertTrue(value.detail.contains("cancelled"))
    }

    func testBusyStateExplainsDisabledModelActions() {
        let value = summary(locked: true, pending: 3)
        XCTAssertEqual(value.title, "Model changes are paused")
        XCTAssertTrue(value.detail.contains("Finish recording"))
        XCTAssertTrue(value.detail.contains("transcription to complete"))
    }

    func testDisabledTranscriptionDoesNotPromiseReadinessOrAutomaticResume() {
        for pending in [0, 3] {
            let value = summary(state: .active, pending: pending, enabled: false)
            XCTAssertEqual(value.title, "Automatic transcription is off")
            XCTAssertFalse(value.detail.contains("resume automatically"))
        }
    }

    @MainActor
    func testReopeningSettingsRefreshesTranscriptionConfig() throws {
        _ = NSApplication.shared
        var enabled = true
        let manager = ModelManager(
            activeModel: .parakeetV3,
            operations: .init(
                isInstalled: { _ in false },
                downloadAndVerify: { _, _, _ in },
                persist: { _ in }
            )
        )
        let controller = SettingsWindowController(
            modelManager: manager, transcriptionEnabled: { enabled }
        )
        defer { controller.close() }
        let host = try XCTUnwrap(controller.window?.contentViewController as? NSHostingController<SettingsView>)
        XCTAssertTrue(host.rootView.transcriptionEnabled)

        enabled = false
        controller.show()
        XCTAssertFalse(host.rootView.transcriptionEnabled)
        controller.close()

        enabled = true
        controller.show()
        XCTAssertTrue(host.rootView.transcriptionEnabled)
    }

    private func summary(
        state: ModelState = .notInstalled,
        preparing: Bool = false,
        locked: Bool = false,
        pending: Int = 0,
        enabled: Bool = true
    ) -> ModelSettingsSummary {
        ModelSettingsSummary(
            activeModel: .parakeetV3, activeState: state, isPreparing: preparing,
            actionsLocked: locked, pendingCount: pending, transcriptionEnabled: enabled
        )
    }
}
