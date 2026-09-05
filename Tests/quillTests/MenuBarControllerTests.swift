import AppKit
import XCTest
@testable import quill

final class MenuBarControllerTests: XCTestCase {
    @MainActor
    func testRecordingTimerRemainsVisibleAfterMicrophoneFailureAndResetsWhenStopped() throws {
        _ = NSApplication.shared
        let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        defer { NSStatusBar.system.removeStatusItem(statusItem) }
        let menu = NSMenu()
        let controller = MenuBarController(menu: menu, statusItem: statusItem)
        let button = try XCTUnwrap(statusItem.button)
        let soundSettings = try XCTUnwrap(menu.item(withTitle: "Open Sound Settings…"))

        XCTAssertEqual(button.title, "")
        XCTAssertEqual(button.accessibilityValue() as? String, "Ready to record")
        controller.update(indicator: .recording, elapsed: "12:34")
        XCTAssertEqual(button.title, "12:34")
        XCTAssertEqual(button.toolTip, "Recording, 12:34")
        XCTAssertEqual(button.accessibilityValue() as? String, "Recording, 12:34")
        XCTAssertNotNil(menu.item(withTitle: "Recording · 12:34"))
        XCTAssertNotNil(menu.item(withTitle: "Stop recording"))
        XCTAssertTrue(soundSettings.isHidden)

        controller.update(indicator: .microphoneFailed, elapsed: "12:35")
        XCTAssertEqual(button.title, "12:35")
        XCTAssertEqual(
            button.accessibilityValue() as? String,
            "Microphone unavailable — system audio recording, 12:35"
        )
        XCTAssertEqual(button.toolTip, button.accessibilityValue() as? String)
        XCTAssertFalse(soundSettings.isHidden)
        XCTAssertNotNil(menu.item(withTitle: "Stop recording"))

        controller.update(indicator: .idle, elapsed: "12:35")
        XCTAssertEqual(button.title, "")
        XCTAssertEqual(button.toolTip, "Ready to record")
        XCTAssertEqual(button.accessibilityValue() as? String, "Ready to record")
        XCTAssertTrue(soundSettings.isHidden)
        XCTAssertNotNil(menu.item(withTitle: "Ready to record"))
        XCTAssertNotNil(menu.item(withTitle: "Start recording"))

        controller.update(indicator: .recording, elapsed: nil)
        XCTAssertEqual(button.title, "0:00")
    }

    @MainActor
    func testWaitingForModelShowsSetupActionAndClearsItForOtherStatuses() throws {
        _ = NSApplication.shared
        let menu = NSMenu()
        let controller = MenuBarController(menu: menu)
        let setup = try XCTUnwrap(menu.item(withTitle: "Set up transcription…"))
        var openedSettings = 0
        controller.onOpenSettings = { openedSettings += 1 }
        XCTAssertTrue(setup.isHidden)

        controller.updateTranscription("2 recordings waiting for a model", needsModel: true)
        XCTAssertFalse(setup.isHidden)
        XCTAssertTrue(setup.isEnabled)
        menu.performActionForItem(at: menu.index(of: setup))
        XCTAssertEqual(openedSettings, 1)

        controller.updateTranscription("Transcribing meeting")
        XCTAssertTrue(setup.isHidden)
        controller.updateTranscription("1 recording waiting for a model", needsModel: true)
        controller.updateTranscription("Transcription failed · meeting")
        XCTAssertTrue(setup.isHidden)
        controller.updateTranscription("1 recording waiting for a model", needsModel: true)
        controller.updateTranscription(nil)
        XCTAssertTrue(setup.isHidden)

        let settings = try XCTUnwrap(menu.item(withTitle: "Settings…"))
        XCTAssertEqual(settings.keyEquivalent, ",")
        menu.performActionForItem(at: menu.index(of: settings))
        XCTAssertEqual(openedSettings, 2)
    }

    @MainActor
    func testPendingSaveRemainsTheAccessibleStatusUntilResolved() throws {
        _ = NSApplication.shared
        let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        defer { NSStatusBar.system.removeStatusItem(statusItem) }
        let controller = MenuBarController(statusItem: statusItem)
        let button = try XCTUnwrap(statusItem.button)
        controller.update(indicator: .idle, elapsed: nil)
        controller.updatePendingSave("meeting")
        XCTAssertEqual(button.accessibilityValue() as? String, "Recording stopped, metadata not saved")
        XCTAssertEqual(button.toolTip, "Recording stopped, metadata not saved")
        controller.update(indicator: .idle, elapsed: nil)
        XCTAssertEqual(button.accessibilityValue() as? String, "Recording stopped, metadata not saved")
        controller.updatePendingSave(nil)
        XCTAssertEqual(button.accessibilityValue() as? String, "Ready to record")
        XCTAssertEqual(button.toolTip, "Ready to record")
    }

    @MainActor
    func testSaveFailureKeepsRetryVisibleAndPreventsAnotherRecording() throws {
        _ = NSApplication.shared
        let menu = NSMenu()
        let controller = MenuBarController(menu: menu)
        let toggle = try XCTUnwrap(menu.item(withTitle: "Start recording"))
        let retry = try XCTUnwrap(menu.item(withTitle: "Retry saving recording"))
        var saved = false
        controller.onRetrySave = { saved = true }
        XCTAssertTrue(retry.isHidden)

        controller.updatePendingSave("test meeting")
        controller.updateModelPreparation(false, recording: false, hasUnsavedRecording: true)
        XCTAssertFalse(retry.isHidden)
        XCTAssertFalse(toggle.isEnabled)
        XCTAssertNotNil(menu.item(withTitle: "Recording not saved · test meeting"))
        menu.performActionForItem(at: menu.index(of: retry))
        XCTAssertTrue(saved)

        controller.updatePendingSave(nil)
        controller.updateModelPreparation(false, recording: false)
        XCTAssertTrue(retry.isHidden)
        XCTAssertTrue(toggle.isEnabled)
    }

    @MainActor
    func testRetryTranscriptionActionAndAvailability() throws {
        _ = NSApplication.shared
        let menu = NSMenu()
        let controller = MenuBarController(menu: menu)
        let retry = try XCTUnwrap(menu.item(withTitle: "Retry pending transcriptions"))
        var retries = 0
        controller.onRetryTranscription = { retries += 1 }

        controller.updateRetryTranscription(enabled: false)
        XCTAssertFalse(retry.isEnabled)
        controller.updateRetryTranscription(enabled: true)
        XCTAssertTrue(retry.isEnabled)
        menu.performActionForItem(at: menu.index(of: retry))
        XCTAssertEqual(retries, 1)
    }

    @MainActor
    func testExistingCaptureCanAlwaysBeStopped() throws {
        _ = NSApplication.shared
        let menu = NSMenu()
        let controller = MenuBarController(menu: menu)
        controller.update(indicator: .recording, elapsed: "0:04")
        controller.updateModelPreparation(true, recording: true, hasUnsavedRecording: true)
        let stop = try XCTUnwrap(menu.item(withTitle: "Stop recording"))
        XCTAssertTrue(stop.isEnabled)
    }
}
