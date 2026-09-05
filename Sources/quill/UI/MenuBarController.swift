import AppKit

/// Status bar item in the top-right of the menu bar. Shows recording state at
/// a glance and provides the only persistent control surface for the daemon
/// (since we run as `.accessory` — no dock icon, no main window).
@MainActor
final class MenuBarController {
    private let statusItem: NSStatusItem
    private let stateLabel: NSMenuItem
    private let transcriptionLabel: NSMenuItem
    private let toggleItem: NSMenuItem
    private let openSoundSettingsItem: NSMenuItem
    private let saveFailureLabel: NSMenuItem
    private let retrySaveItem: NSMenuItem
    private let retryTranscriptionItem: NSMenuItem
    private let setupTranscriptionItem: NSMenuItem
    private var recordingAccessibilityValue = "Ready to record"

    var onToggle: (() -> Void)?
    var onOpenSoundSettings: (() -> Void)?
    var onOpenSettings: (() -> Void)?
    var onOpenFolder: (() -> Void)?
    var onQuit: (() -> Void)?
    var onRetrySave: (() -> Void)?
    var onRetryTranscription: (() -> Void)?

    init(menu: NSMenu = NSMenu(), statusItem: NSStatusItem? = nil) {
        self.statusItem = statusItem
            ?? NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

        menu.autoenablesItems = false

        stateLabel = NSMenuItem(title: "Ready to record", action: nil, keyEquivalent: "")
        stateLabel.isEnabled = false
        menu.addItem(stateLabel)

        transcriptionLabel = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        transcriptionLabel.isEnabled = false
        transcriptionLabel.isHidden = true
        menu.addItem(transcriptionLabel)

        saveFailureLabel = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        saveFailureLabel.isEnabled = false
        saveFailureLabel.isHidden = true
        menu.addItem(saveFailureLabel)

        menu.addItem(.separator())

        toggleItem = NSMenuItem(
            title: "Start recording",
            action: #selector(toggleClicked),
            keyEquivalent: "r"
        )
        menu.addItem(toggleItem)

        retrySaveItem = NSMenuItem(
            title: "Retry saving recording",
            action: #selector(retrySaveClicked),
            keyEquivalent: ""
        )
        retrySaveItem.isHidden = true
        menu.addItem(retrySaveItem)

        retryTranscriptionItem = NSMenuItem(
            title: "Retry pending transcriptions",
            action: #selector(retryTranscriptionClicked),
            keyEquivalent: ""
        )
        menu.addItem(retryTranscriptionItem)

        setupTranscriptionItem = NSMenuItem(
            title: "Set up transcription…",
            action: #selector(openSettingsClicked),
            keyEquivalent: ""
        )
        setupTranscriptionItem.image = NSImage(
            systemSymbolName: "arrow.down.circle",
            accessibilityDescription: nil
        )
        setupTranscriptionItem.isHidden = true
        menu.addItem(setupTranscriptionItem)

        openSoundSettingsItem = NSMenuItem(
            title: "Open Sound Settings…",
            action: #selector(openSoundSettingsClicked),
            keyEquivalent: ""
        )
        openSoundSettingsItem.isHidden = true
        menu.addItem(openSoundSettingsItem)

        let openFolder = NSMenuItem(
            title: "Open recordings folder",
            action: #selector(openFolderClicked),
            keyEquivalent: "o"
        )
        menu.addItem(openFolder)

        menu.addItem(.separator())

        let settings = NSMenuItem(
            title: "Settings…",
            action: #selector(openSettingsClicked),
            keyEquivalent: ","
        )
        menu.addItem(settings)

        menu.addItem(.separator())

        let quit = NSMenuItem(
            title: "Quit quill",
            action: #selector(quitClicked),
            keyEquivalent: "q"
        )
        menu.addItem(quit)

        for item in [toggleItem, retrySaveItem, retryTranscriptionItem, setupTranscriptionItem,
                     openSoundSettingsItem, openFolder, settings, quit] {
            item.target = self
        }

        self.statusItem.menu = menu

        if let button = self.statusItem.button {
            button.imagePosition = .imageLeft
            button.font = .monospacedDigitSystemFont(
                ofSize: NSFont.menuBarFont(ofSize: 0).pointSize, weight: .regular
            )
            button.setAccessibilityLabel("Quill")
        }
        update(indicator: .idle, elapsed: nil)
    }

    /// Reflect recording state in the icon and menu item titles. The
    /// elapsed counter remains visible in the menu bar while recording,
    /// including when only system audio is available. Call once a second.
    func update(indicator: RecordingIndicator, elapsed: String?) {
        switch indicator {
        case .idle:
            stateLabel.title = "Ready to record"
        case .recording:
            stateLabel.title = "Recording · \(elapsed ?? "0:00")"
        case .microphoneFailed:
            stateLabel.title = "Microphone unavailable — system audio recording"
        }
        toggleItem.title = indicator == .idle ? "Start recording" : "Stop recording"
        toggleItem.image = NSImage(
            systemSymbolName: indicator == .idle ? "record.circle" : "stop.circle",
            accessibilityDescription: nil
        )
        openSoundSettingsItem.isHidden = indicator != .microphoneFailed
        let image: NSImage?
        switch indicator {
        case .idle:
            image = Self.featherImage()
        case .recording:
            image = Self.recordingImage()
        case .microphoneFailed:
            image = Self.microphoneFailedImage()
        }
        image?.isTemplate = true
        statusItem.button?.image = image
        statusItem.button?.title = indicator == .idle ? "" : (elapsed ?? "0:00")
        statusItem.button?.setAccessibilityLabel("Quill")
        let accessibilityValue = switch indicator {
        case .idle: "Ready to record"
        case .recording: "Recording, \(elapsed ?? "0:00")"
        case .microphoneFailed: "Microphone unavailable — system audio recording, \(elapsed ?? "0:00")"
        }
        recordingAccessibilityValue = accessibilityValue
        updateAccessibilityValue()
    }

    /// Prevent a new recording while model download or verification is active.
    /// An existing recording can always be stopped.
    func updateModelPreparation(
        _ isPreparing: Bool, recording: Bool, hasUnsavedRecording: Bool = false
    ) {
        toggleItem.isEnabled = recording || (!isPreparing && !hasUnsavedRecording)
        toggleItem.toolTip = nil
        if !recording {
            if hasUnsavedRecording {
                toggleItem.toolTip = "Retry saving the stopped recording before starting another"
            } else if isPreparing {
                toggleItem.toolTip = "Recording is unavailable while a transcription model is being prepared"
            }
        }
    }

    func updatePendingSave(_ session: String?) {
        saveFailureLabel.title = session.map { "Recording not saved · \($0)" } ?? ""
        saveFailureLabel.isHidden = session == nil
        retrySaveItem.isHidden = session == nil
        updateAccessibilityValue()
    }

    func updateRetryTranscription(enabled: Bool) {
        retryTranscriptionItem.isEnabled = enabled
    }

    private func updateAccessibilityValue() {
        let value = saveFailureLabel.isHidden
            ? recordingAccessibilityValue
            : "Recording stopped, metadata not saved"
        statusItem.button?.setAccessibilityValue(value)
        statusItem.button?.toolTip = value
    }

    /// Show transcription progress/failure as a second status line in the
    /// menu; nil hides it. Independent of recording state — a new recording
    /// can run while the last one transcribes.
    func updateTranscription(_ text: String?, needsModel: Bool = false) {
        transcriptionLabel.title = text ?? ""
        transcriptionLabel.isHidden = text == nil
        setupTranscriptionItem.isHidden = !needsModel || text == nil
    }

    // Inlined Lucide feather SVG. Keeping it in source means the executable
    // has no separate resource bundle to install alongside it — true
    // single-binary.
    private static let featherSVG = """
    <svg xmlns="http://www.w3.org/2000/svg" width="24" height="24" \
    viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.5" \
    stroke-linecap="round" stroke-linejoin="round">\
    <path d="M12.67 19a2 2 0 0 0 1.416-.588l6.154-6.172a6 6 0 0 0-8.49-8.49L5.586 9.914A2 2 0 0 0 5 11.328V18a1 1 0 0 0 1 1z"/>\
    <path d="M16 8 2 22"/>\
    <path d="M17.5 15H9"/>\
    </svg>
    """

    private static func featherImage() -> NSImage? {
        guard let data = featherSVG.data(using: .utf8),
              let image = NSImage(data: data)
        else { return nil }
        // Menu-bar status icons are nominally 18pt tall; size the SVG to match.
        image.size = NSSize(width: 16, height: 16)
        return image
    }

    private static func recordingImage() -> NSImage? {
        NSImage(
            systemSymbolName: "stop.fill",
            accessibilityDescription: "Quill is recording"
        )
    }

    private static func microphoneFailedImage() -> NSImage? {
        NSImage(
            systemSymbolName: "exclamationmark.triangle.fill",
            accessibilityDescription: "Microphone unavailable"
        )
    }

    @objc private func toggleClicked() { onToggle?() }
    @objc private func openSoundSettingsClicked() { onOpenSoundSettings?() }
    @objc private func openSettingsClicked() { onOpenSettings?() }
    @objc private func openFolderClicked() { onOpenFolder?() }
    @objc private func quitClicked() { onQuit?() }
    @objc private func retrySaveClicked() { onRetrySave?() }
    @objc private func retryTranscriptionClicked() { onRetryTranscription?() }
}
