import SwiftUI

/// A small presentation value keeps readiness copy consistent with the controls
/// below it, including when automatic transcription is disabled in config.
struct ModelSettingsSummary: Equatable {
    let title: String
    let detail: String
    let symbol: String

    init(
        activeModel: TranscriptionModel,
        activeState: ModelState,
        isPreparing: Bool,
        actionsLocked: Bool,
        pendingCount: Int,
        transcriptionEnabled: Bool
    ) {
        if isPreparing {
            title = "Preparing a model"
            detail = "Recording is unavailable until preparation finishes or is cancelled."
            symbol = "arrow.down.circle"
        } else if actionsLocked {
            title = "Model changes are paused"
            detail = "Finish recording or wait for transcription to complete to change models."
            symbol = "lock"
        } else if !transcriptionEnabled {
            title = "Automatic transcription is off"
            detail = "Recordings are saved as audio. Enable transcription in your Quill config to transcribe them."
            symbol = "waveform"
        } else if pendingCount > 0 {
            title = "\(pendingCount) recording\(pendingCount == 1 ? "" : "s") waiting"
            detail = "Download or activate a model below. Waiting recordings resume automatically."
            symbol = "clock"
        } else if activeState == .active {
            title = "Ready to transcribe"
            detail = "New recordings use \(activeModel.displayName) on this Mac."
            symbol = "checkmark.circle"
        } else {
            title = "Set up transcription"
            detail = "You can record now. Download a model below to transcribe your recordings."
            symbol = "arrow.down.circle"
        }
    }
}

struct SettingsView: View {
    @ObservedObject var modelManager: ModelManager
    @ObservedObject var notesManager: NotesModelManager = .shared
    var transcriptionEnabled: Bool

    private var summary: ModelSettingsSummary {
        ModelSettingsSummary(
            activeModel: modelManager.activeModel,
            activeState: modelManager.state(for: modelManager.activeModel),
            isPreparing: modelManager.isPreparingModel,
            actionsLocked: modelManager.actionsLocked,
            pendingCount: modelManager.pendingCount,
            transcriptionEnabled: transcriptionEnabled
        )
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Text("Models")
                    .font(.title.weight(.semibold))
                    .accessibilityAddTraits(.isHeader)

                VStack(alignment: .leading, spacing: 4) {
                    Text("Speech to text").font(.title2.weight(.semibold))
                    Text("Turn recordings into a transcript.")
                        .font(.callout).foregroundStyle(.secondary)
                }

                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: summary.symbol)
                        .font(.title3)
                        .foregroundStyle(.secondary)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(summary.title)
                            .font(.headline)
                        Text(summary.detail)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .accessibilityElement(children: .combine)

                VStack(spacing: 0) {
                    ForEach(TranscriptionModel.allCases) { model in
                        Divider()
                        ModelRow(model: model, manager: modelManager)
                    }
                    Divider()
                }

                VStack(alignment: .leading, spacing: 4) {
                    Text("Meeting notes").font(.title2.weight(.semibold))
                        .accessibilityAddTraits(.isHeader)
                    Text("Experimental. New imports automatically produce notes after transcription when a notes model is ready. Wording edits and source playback are optional.")
                        .font(.callout).foregroundStyle(.secondary)
                    Text("Models load only when you generate notes and unload when the job finishes. Download once; generation works offline.")
                        .font(.callout).foregroundStyle(.secondary)
                }

                VStack(spacing: 0) {
                    ForEach(NotesModel.allCases) { model in
                        Divider()
                        NotesModelRow(model: model, manager: notesManager)
                    }
                    Divider()
                }

                Label("Models run locally. Audio and transcripts stay on this Mac.", systemImage: "lock.shield")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .frame(minWidth: 520, minHeight: 430)
    }
}

private struct NotesModelRow: View {
    let model: NotesModel
    @ObservedObject var manager: NotesModelManager
    private var state: ModelState { manager.state(for: model) }
    private var locked: Bool { manager.actionsLocked || manager.isPreparingModel }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text(model.displayName).font(.headline)
                Spacer()
                if state == .active {
                    Label("Selected", systemImage: "checkmark.circle.fill")
                        .font(.callout).foregroundStyle(.secondary)
                }
            }
            Text("\(ByteCountFormatter.string(fromByteCount: Int64(model.downloadBytes), countStyle: .file)) download · 4-bit")
                .font(.callout).foregroundStyle(.secondary)
            switch state {
            case .downloading(let fraction):
                ProgressView(value: fraction).accessibilityLabel("Downloading \(model.displayName)")
                Text("Downloading · \(Int(fraction * 100))%")
                    .font(.callout).foregroundStyle(.secondary)
                Button("Cancel", action: manager.cancel)
            case .verifying:
                ProgressView().controlSize(.small)
                Text("Verifying the download…").font(.callout).foregroundStyle(.secondary)
                Button("Cancel", action: manager.cancel)
            case .active:
                Text("Used for automatic notes after import and when you choose Generate notes.")
                    .font(.callout).foregroundStyle(.secondary)
            case .installed:
                Button("Use for notes") { manager.activate(model) }.disabled(locked)
            case .notInstalled:
                Button("Download and use") { Task { await manager.downloadAndUse(model) } }.disabled(locked)
            case .failed(let message), .activationFailed(let message):
                Text(message).font(.callout).foregroundStyle(.red).textSelection(.enabled)
                Button("Retry") { Task { await manager.downloadAndUse(model) } }.disabled(locked)
            }
        }
        .buttonStyle(.bordered)
        .padding(.vertical, 16)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct ModelRow: View {
    let model: TranscriptionModel
    @ObservedObject var manager: ModelManager

    private var state: ModelState { manager.state(for: model) }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 4) {
                Text(model.displayName)
                    .font(.headline)
                    .accessibilityAddTraits(.isHeader)
                Text(model.isRecommended ? "Recommended · \(model.providerName) · \(model.approximateSize)" : "\(model.providerName) · \(model.approximateSize)")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            VStack(alignment: .leading, spacing: 3) {
                Text(model.recommendation)
                Text(model.languageSummary)
                    .foregroundStyle(.secondary)
            }
            .font(.callout)
            .fixedSize(horizontal: false, vertical: true)

            stateDetail

            HStack(spacing: 12) {
                stateLabel
                    .font(.callout)
                Spacer(minLength: 8)
                action
                    .buttonStyle(.bordered)
                    .buttonBorderShape(.roundedRectangle(radius: 5))
                    .controlSize(.regular)
            }
        }
        .padding(.vertical, 18)
    }

    @ViewBuilder
    private var stateLabel: some View {
        switch state {
        case .active:
            Label("Active model", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.primary)
        case .installed:
            Text("Downloaded")
                .foregroundStyle(.secondary)
        case .notInstalled:
            Text("Not downloaded")
                .foregroundStyle(.secondary)
        case .downloading:
            Text("Step 1 of 2 · Download")
                .foregroundStyle(.secondary)
        case .verifying:
            Text("Step 2 of 2 · Verify")
                .foregroundStyle(.secondary)
        case .failed:
            Label("Preparation failed", systemImage: "exclamationmark.triangle")
        case .activationFailed:
            Label("Activation failed", systemImage: "exclamationmark.triangle")
        }
    }

    @ViewBuilder
    private var stateDetail: some View {
        switch state {
        case .downloading(let progress):
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("Downloading model…")
                    Spacer()
                    Text(progress, format: .percent.precision(.fractionLength(0)))
                        .monospacedDigit()
                }
                .font(.callout)
                ProgressView(value: progress)
                    .accessibilityLabel("Downloading \(model.displayName)")
            }
        case .verifying:
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                    .accessibilityLabel("Verifying \(model.displayName)")
                Text("Checking the model before activation…")
                    .font(.callout)
            }
        case .failed(let message), .activationFailed(let message):
            VStack(alignment: .leading, spacing: 6) {
                Text(message)
                    .textSelection(.enabled)
                if case .activationFailed = state {
                    Text("The model is downloaded. Retry activation without downloading again.")
                        .foregroundStyle(.secondary)
                }
            }
            .font(.callout)
            .fixedSize(horizontal: false, vertical: true)
        default:
            EmptyView()
        }
    }

    @ViewBuilder
    private var action: some View {
        switch state {
        case .notInstalled:
            Button("Download & Use") {
                Task { await manager.downloadAndUse(model) }
            }
            .disabled(actionsDisabled)
            .accessibilityLabel("Download and use \(model.displayName)")
            .help(actionUnavailableHelp ?? "Download, verify, and use this model")
        case .downloading, .verifying:
            Button("Cancel") { manager.cancel() }
                .keyboardShortcut(.cancelAction)
                .accessibilityLabel("Cancel preparation of \(model.displayName)")
                .help("Cancel model preparation (Esc)")
        case .installed:
            Button("Use Model") { manager.activate(model) }
                .disabled(actionsDisabled)
                .accessibilityLabel("Use \(model.displayName)")
                .help(actionUnavailableHelp ?? "Use this model for future transcriptions")
        case .active:
            EmptyView()
        case .failed:
            Button("Retry Download") {
                Task { await manager.downloadAndUse(model) }
            }
            .disabled(actionsDisabled)
            .accessibilityLabel("Retry downloading \(model.displayName)")
            .help(actionUnavailableHelp ?? "Retry downloading and verifying this model")
        case .activationFailed:
            Button("Retry Activation") { manager.activate(model) }
                .disabled(actionsDisabled)
                .accessibilityLabel("Retry activating \(model.displayName)")
                .help(actionUnavailableHelp ?? "Retry activating this installed model")
        }
    }

    private var actionsDisabled: Bool {
        manager.actionsLocked || manager.isPreparingModel
    }

    private var actionUnavailableHelp: String? {
        if manager.actionsLocked {
            return "Model changes are unavailable while recording or transcribing"
        }
        if manager.isPreparingModel {
            return "Model changes are unavailable while another model is being prepared"
        }
        return nil
    }
}
