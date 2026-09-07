import AppKit
import SwiftUI

@MainActor
final class MeetingWindowController: NSWindowController, NSWindowDelegate {
    let model: MeetingEditorModel

    init(root: URL, modelProvider: @escaping () -> TranscriptionModel,
         canAnalyze: @escaping () -> Bool = { true }, onBusyChanged: @escaping (Bool) -> Void = { _ in },
         noteGenerator: MeetingNoteGenerator? = nil) {
        model = MeetingEditorModel(root: root, modelProvider: modelProvider, canAnalyze: canAnalyze, onBusyChanged: onBusyChanged, noteGenerator: noteGenerator)
        let hosting = NSHostingController(rootView: MeetingEditorView(model: model))
        let window = MeetingEditorWindow(contentViewController: hosting)
        window.editorModel = model
        window.title = "Quill · Recorded Meetings"
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.setContentSize(NSSize(width: 1180, height: 800))
        window.contentMinSize = NSSize(width: 900, height: 650)
        window.isReleasedWhenClosed = false
        window.setFrameAutosaveName("QuillMeetingEditor")
        super.init(window: window)
        window.delegate = self
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func show() { NSApp.activate(); window?.makeKeyAndOrderFront(nil) }
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        model.pause()
        return model.persist()
    }
}

/// Local editor shortcuts never intercept name fields or another Quill window.
@MainActor
private final class MeetingEditorWindow: NSWindow {
    weak var editorModel: MeetingEditorModel?
    override func sendEvent(_ event: NSEvent) {
        // A menu-bar app has no standard Edit menu to route these commands.
        // Keep normal text editing available inside speaker-name fields.
        if event.type == .keyDown, let field = firstResponder as? NSTextView,
           event.modifierFlags.intersection([.command, .control, .option]) == .command,
           (event.charactersIgnoringModifiers ?? "").lowercased() == "z" {
            if event.modifierFlags.contains(.shift) { field.undoManager?.redo() }
            else { field.undoManager?.undo() }
            return
        }
        if event.type == .keyDown, let field = firstResponder as? NSTextView,
           event.modifierFlags.intersection([.command, .control, .option, .shift]) == .command {
            switch (event.charactersIgnoringModifiers ?? "").lowercased() {
            case "a": field.selectAll(nil); return
            case "c": field.copy(nil); return
            case "x": field.cut(nil); return
            case "v": field.paste(nil); return
            default: break
            }
        }
        if event.type == .keyDown, !(firstResponder is NSTextView), let model = editorModel {
            let key = (event.charactersIgnoringModifiers ?? "").lowercased()
            if event.modifierFlags.contains(.command), key == "z" {
                if event.modifierFlags.contains(.shift) { model.redo() } else { model.undo() }
                return
            }
            if event.modifierFlags.intersection([.command, .control, .option]).isEmpty {
                if key == " " { model.togglePlayback(); return }
                if let number = Int(key), number >= 1, let speakers = model.document?.speakers, number <= speakers.count {
                    model.assign([speakers[number - 1].id]); return
                }
                if key == "0" { model.assign([]); return }
            }
        }
        super.sendEvent(event)
    }
}
