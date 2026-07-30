import SwiftUI

struct SettingsView: View {
    @ObservedObject var modelManager: ModelManager

    var body: some View {
        Form {
            if modelManager.pendingCount > 0 {
                Section {
                    Label(
                        "\(modelManager.pendingCount) recording\(modelManager.pendingCount == 1 ? "" : "s") waiting for a transcription model",
                        systemImage: "clock.badge.exclamationmark"
                    )
                    .foregroundStyle(.secondary)
                    .accessibilityLabel(
                        "\(modelManager.pendingCount) pending transcription\(modelManager.pendingCount == 1 ? "" : "s")"
                    )
                }
            }

            Section {
                ForEach(TranscriptionModel.allCases) { model in
                    ModelRow(model: model, manager: modelManager)
                }
            } header: {
                Text("Transcription Model")
            } footer: {
                Text("Models run locally. Audio and transcripts do not leave this Mac.")
            }
        }
        .formStyle(.grouped)
        .frame(minWidth: 520, minHeight: 430)
    }
}

private struct ModelRow: View {
    let model: TranscriptionModel
    @ObservedObject var manager: ModelManager

    private var state: ModelState {
        manager.state(for: model)
    }

    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            stateIcon
                .font(.title2)
                .frame(width: 24)

            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    Text(model.displayName)
                        .font(.headline)

                    if model.isRecommended {
                        Text("Recommended")
                            .font(.caption.weight(.semibold))
                            .padding(.horizontal, 7)
                            .padding(.vertical, 2)
                            .background(.tint.opacity(0.14), in: Capsule())
                            .foregroundStyle(.tint)
                            .accessibilityLabel("Recommended model")
                    }
                }

                Text(model.providerName)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(model.recommendation)
                Text(model.languageSummary)
                    .foregroundStyle(.secondary)

                HStack(spacing: 12) {
                    Label(model.approximateSize, systemImage: "internaldrive")
                    Label("Local only", systemImage: "lock.shield")
                }
                .font(.caption)
                .foregroundStyle(.secondary)

                stateDetail
            }

            Spacer(minLength: 12)
            action
        }
        .padding(.vertical, 8)
    }

    @ViewBuilder
    private var stateIcon: some View {
        switch state {
        case .notInstalled:
            Image(systemName: "arrow.down.circle")
                .foregroundStyle(.secondary)
                .accessibilityLabel("Not downloaded")
                .help("This model is not downloaded")
        case .downloading:
            Image(systemName: "arrow.down.circle.fill")
                .foregroundStyle(.tint)
                .accessibilityLabel("Downloading")
                .help("This model is downloading")
        case .verifying:
            Image(systemName: "checkmark.shield")
                .foregroundStyle(.tint)
                .accessibilityLabel("Verifying")
                .help("Quill is verifying this model")
        case .installed:
            Image(systemName: "checkmark.circle")
                .foregroundStyle(.secondary)
                .accessibilityLabel("Downloaded")
                .help("This model is downloaded and ready to use")
        case .active:
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.green)
                .accessibilityLabel("Active model")
                .help("This model is active")
        case .failed:
            Image(systemName: "exclamationmark.triangle")
                .foregroundStyle(.orange)
                .accessibilityLabel("Model preparation failed")
                .help("Model preparation failed")
        case .activationFailed:
            Image(systemName: "exclamationmark.triangle")
                .foregroundStyle(.orange)
                .accessibilityLabel("Model activation failed")
                .help("Model activation failed")
        }
    }

    @ViewBuilder
    private var stateDetail: some View {
        switch state {
        case .downloading(let progress):
            ProgressView(value: progress) {
                Text("Downloading…")
            } currentValueLabel: {
                Text(progress, format: .percent.precision(.fractionLength(0)))
            }
            .accessibilityLabel("Downloading \(model.displayName)")
        case .verifying:
            ProgressView("Verifying…")
                .accessibilityLabel("Verifying \(model.displayName)")
        case .failed(let message), .activationFailed(let message):
            Text(message)
                .font(.caption)
                .foregroundStyle(.red)
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
            .help(actionUnavailableHelp ?? "Download, verify, and use this model")
        case .downloading, .verifying:
            Button {
                manager.cancel()
            } label: {
                Image(systemName: "xmark.circle")
            }
            .buttonStyle(.borderless)
            .accessibilityLabel("Cancel model download")
            .help("Cancel download")
        case .installed:
            Button("Use Model") {
                manager.activate(model)
            }
            .disabled(actionsDisabled)
            .help(actionUnavailableHelp ?? "Use this model for future transcriptions")
        case .active:
            Text("Active")
                .foregroundStyle(.secondary)
                .accessibilityLabel("\(model.displayName) is active")
        case .failed:
            Button("Retry") {
                Task { await manager.downloadAndUse(model) }
            }
            .disabled(actionsDisabled)
            .help(actionUnavailableHelp ?? "Retry downloading and verifying this model")
        case .activationFailed:
            Button("Retry Activation") {
                manager.activate(model)
            }
            .disabled(actionsDisabled)
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
