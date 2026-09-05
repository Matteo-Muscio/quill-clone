import AppKit
import XCTest
@testable import quill

final class MenuBarControllerTests: XCTestCase {
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
