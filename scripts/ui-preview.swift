// Native visual fixture using the real compiled Quill views. No audio, network, or config writes.
import AppKit
import SwiftUI
@testable import quill

@MainActor
final class Preview: NSObject {
    var settings: SettingsWindowController?
    var manager: ModelManager?
    var menuController: MenuBarController?
    let menu = NSMenu()
    var fixture = "Ready"

    func start() {
        let main = NSMenu()
        let item = NSMenuItem(title: "Preview", action: nil, keyEquivalent: "")
        let submenu = NSMenu()
        for (index, name) in ["Ready", "Setup", "Locked", "Download", "Verifying", "Failure", "Activation failure", "Recording", "Microphone failure"].enumerated() {
            let command = NSMenuItem(title: name, action: #selector(selectFixture(_:)), keyEquivalent: String(index + 1))
            command.target = self
            submenu.addItem(command)
        }
        submenu.addItem(.separator())
        for name in ["Light appearance", "Dark appearance", "Compact window", "Default window"] {
            let command = NSMenuItem(title: name, action: #selector(changePresentation(_:)), keyEquivalent: "")
            command.target = self
            submenu.addItem(command)
        }
        submenu.addItem(.separator())
        let show = NSMenuItem(title: "Show Quill menu", action: #selector(showMenu), keyEquivalent: "m")
        show.target = self
        submenu.addItem(show)
        let quit = NSMenuItem(title: "Quit Preview", action: #selector(quit), keyEquivalent: "q")
        quit.target = self
        submenu.addItem(quit)
        item.submenu = submenu
        main.addItem(item)
        NSApp.mainMenu = main
        menuController = MenuBarController(menu: menu)
        menuController?.onOpenSettings = { [weak self] in self?.settings?.show() }
        menuController?.onToggle = { [weak self] in
            self?.menuController?.update(indicator: .idle, elapsed: nil)
        }
        apply("Ready")
    }

    @objc func selectFixture(_ sender: NSMenuItem) { apply(sender.title) }
    @objc func showMenu() { menu.popUp(positioning: nil, at: NSPoint(x: 850, y: 720), in: nil) }
    @objc func changePresentation(_ sender: NSMenuItem) {
        switch sender.title {
        case "Light appearance": NSApp.appearance = NSAppearance(named: .aqua)
        case "Dark appearance": NSApp.appearance = NSAppearance(named: .darkAqua)
        case "Compact window": settings?.window?.setContentSize(NSSize(width: 520, height: 430))
        default: settings?.window?.setContentSize(NSSize(width: 600, height: 540))
        }
    }
    @objc func quit() { NSApp.terminate(nil) }

    func apply(_ name: String) {
        manager?.cancel()
        fixture = name
        settings?.close()
        let installed = ["Ready", "Locked", "Recording", "Microphone failure"].contains(name)
        let modelManager = ModelManager(
            activeModel: .parakeetV3,
            actionsLocked: name == "Locked",
            pendingCount: name == "Setup" ? 3 : 0,
            operations: .init(
                isInstalled: { model in installed && model == .parakeetV3 },
                downloadAndVerify: { _, progress, verifying in
                    if name == "Failure" {
                        throw NSError(domain: "Preview", code: 1, userInfo: [NSLocalizedDescriptionKey: "The internet connection was interrupted. Check your connection and try again."])
                    }
                    if name == "Activation failure" { return }
                    progress(0.42)
                    if name == "Verifying" { verifying() }
                    try await Task.sleep(for: .seconds(300))
                },
                persist: { _ in
                    if name == "Activation failure" {
                        throw NSError(domain: "Preview", code: 2, userInfo: [NSLocalizedDescriptionKey: "The configuration file could not be saved. Check folder access and try again."])
                    }
                }
            )
        )
        manager = modelManager
        settings = SettingsWindowController(modelManager: modelManager)
        settings?.window?.setFrameAutosaveName("")
        settings?.window?.setContentSize(NSSize(width: 600, height: 540))
        settings?.window?.center()
        settings?.show()
        menuController?.update(indicator: name == "Microphone failure" ? .microphoneFailed : (name == "Recording" ? .recording : .idle), elapsed: "12:34")
        menuController?.updateTranscription(name == "Setup" ? "3 recordings waiting for a model" : nil, needsModel: name == "Setup")
        if ["Download", "Verifying", "Failure", "Activation failure"].contains(name) {
            Task { await modelManager.downloadAndUse(.parakeetV3) }
        }
    }
}

@main
struct Entry {
    @MainActor static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.regular)
        let preview = Preview()
        preview.start()
        withExtendedLifetime(preview) { app.run() }
    }
}
