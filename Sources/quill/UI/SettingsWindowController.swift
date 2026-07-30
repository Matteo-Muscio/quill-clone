import AppKit
import SwiftUI

@MainActor
final class SettingsWindowController: NSWindowController {
    init(modelManager: ModelManager) {
        let hostingController = NSHostingController(
            rootView: SettingsView(modelManager: modelManager)
        )
        let window = NSWindow(contentViewController: hostingController)
        window.title = "Quill Settings"
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.setContentSize(NSSize(width: 560, height: 480))
        window.minSize = NSSize(width: 520, height: 430)
        window.isReleasedWhenClosed = false
        window.setFrameAutosaveName("QuillSettingsWindow")

        super.init(window: window)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func show() {
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
}
