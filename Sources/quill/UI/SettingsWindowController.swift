import AppKit
import SwiftUI

@MainActor
final class SettingsWindowController: NSWindowController {
    private let hostingController: NSHostingController<SettingsView>
    private let transcriptionEnabled: () -> Bool

    init(
        modelManager: ModelManager,
        transcriptionEnabled: @escaping () -> Bool = { Config.transcriptionEnabled() }
    ) {
        self.transcriptionEnabled = transcriptionEnabled
        hostingController = NSHostingController(
            rootView: SettingsView(
                modelManager: modelManager,
                transcriptionEnabled: transcriptionEnabled()
            )
        )
        let window = NSWindow(contentViewController: hostingController)
        window.title = "Quill Settings"
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.setContentSize(NSSize(width: 600, height: 540))
        window.contentMinSize = NSSize(width: 520, height: 430)
        window.isReleasedWhenClosed = false
        window.setFrameAutosaveName("QuillSettingsWindow")

        super.init(window: window)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func show() {
        // Config can be edited while the daemon is running.
        hostingController.rootView.transcriptionEnabled = transcriptionEnabled()
        NSApp.activate()
        window?.makeKeyAndOrderFront(nil)
    }
}
