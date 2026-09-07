import SwiftUI
import UniformTypeIdentifiers

private enum MeetingStyle {
    static let inset: CGFloat = 20
    static let colors: [Color] = [.blue, .orange, .teal, .purple, .pink, .indigo, .brown, .cyan, .green]
}

struct MeetingEditorView: View {
    @ObservedObject var model: MeetingEditorModel
    @State private var dropTarget = false

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if let document = model.document {
                workspace(document)
            } else {
                empty
            }
            Divider()
            footer
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .buttonStyle(.bordered)
        .controlSize(.regular)
        .disabled(model.isExternallyLocked)
        .frame(minWidth: 900, minHeight: 650)
        .overlay { if dropTarget { Rectangle().stroke(Color.accentColor, lineWidth: 3).allowsHitTesting(false) } }
        .onDrop(of: [UTType.fileURL], isTargeted: $dropTarget) { providers in
            guard !model.isBusy, let provider = providers.first else { return false }
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                if let url { Task { @MainActor in model.importRecording(url) } }
            }
            return true
        }
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(model.document?.title ?? "Recorded meetings")
                    .font(.system(size: 20, weight: .semibold)).lineLimit(1)
                    .accessibilityAddTraits(.isHeader)
                Text(model.document.map { "\(meetingTime($0.duration)) · Original recording preserved" } ?? "Record on your phone. Review on your Mac.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            Spacer(minLength: 12)
            Menu("Recent") {
                if model.recent.isEmpty { Text("No saved meetings") }
                ForEach(model.recent) { session in
                    Button("\(session.title) · \(meetingTime(session.duration))") { model.open(session.id) }
                }
            }.fixedSize().disabled(model.isBusy)
            Button("Import recording…", systemImage: "square.and.arrow.down") { model.chooseRecording() }
                .disabled(model.isBusy)
        }.padding(.horizontal, MeetingStyle.inset).padding(.vertical, 14)
    }

    private var empty: some View {
        VStack(alignment: .leading, spacing: 18) {
            Spacer()
            Image(systemName: "waveform").font(.system(size: 42, weight: .light)).foregroundStyle(.secondary)
            Text("A conversation, ready to untangle.").font(.system(size: 28, weight: .medium))
            Text("Drop an iPhone Voice Memo or another audio recording here.\nQuill creates a visual timeline so you can review who said what.")
                .font(.body).foregroundStyle(.secondary).lineSpacing(5)
            Button("Choose a recording…") { model.chooseRecording() }
            HStack(spacing: 8) {
                Image(systemName: "lock.shield")
                Text("Audio and transcription stay on this Mac.")
            }.font(.callout).foregroundStyle(.secondary).padding(.top, 10)
            Spacer()
        }.frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 56)
    }

    private func workspace(_ document: MeetingDocument) -> some View {
        VStack(spacing: 0) {
            participantBar(document)
            Divider()
            transport(document)
            MeetingTimeline(model: model)
                .frame(minHeight: 190, idealHeight: min(400, CGFloat(document.speakers.count + 1) * 52 + 116), maxHeight: min(400, CGFloat(document.speakers.count + 1) * 52 + 116))
                .layoutPriority(1)
            Divider()
            correctionBar(document)
            Divider()
            transcript(document)
        }
    }

    private func participantBar(_ document: MeetingDocument) -> some View {
        HStack(alignment: .center, spacing: 14) {
            if !model.hasAnalysis {
                Stepper(value: Binding(get: { model.participantCount }, set: { model.participantCount = $0; model.configureSpeakers() }), in: 1...9) {
                    Text("\(model.participantCount) participants").fontWeight(.medium)
                }.fixedSize().disabled(model.isBusy)
            } else {
                Text("Speakers").font(.callout.weight(.semibold))
            }
            ScrollView(.horizontal) {
                HStack(spacing: 10) {
                    ForEach(Array(document.speakers.enumerated()), id: \.element.id) { index, speaker in
                        HStack(spacing: 5) {
                            Text("\(index + 1)").font(.caption.monospaced()).foregroundStyle(MeetingStyle.colors[index % MeetingStyle.colors.count])
                            MeetingSpeakerNameField(model: model, documentID: document.id, speaker: speaker, number: index + 1)
                                .id(document.id + speaker.id)
                        }
                    }
                }
            }.scrollIndicators(.hidden)
            if !model.hasAnalysis {
                Button("Transcribe", systemImage: "text.bubble") { model.transcribe() }
                    .disabled(model.isBusy || document.duration <= 0)
            } else {
                Button("Refine remaining audio", systemImage: "arrow.triangle.2.circlepath") { model.refine() }
                    .disabled(model.isBusy || !document.regions.contains(where: { $0.isConfirmed }))
                    .help("Use confirmed examples to reconsider unreviewed segments. Confirmed edits stay fixed.")
            }
        }.padding(.horizontal, MeetingStyle.inset).padding(.vertical, 12)
    }

    private func transport(_ document: MeetingDocument) -> some View {
        HStack(spacing: 12) {
            Button { model.seek(model.playhead - 5) } label: { Image(systemName: "gobackward.5") }
                .accessibilityLabel("Back five seconds")
            Button { model.togglePlayback() } label: {
                Label(model.isPlaying ? "Pause" : "Play", systemImage: model.isPlaying ? "pause.fill" : "play.fill").frame(width: 62)
            }.disabled(document.duration <= 0 || !model.isPlaybackAvailable)
            Button { model.seek(model.playhead + 5) } label: { Image(systemName: "goforward.5") }
                .accessibilityLabel("Forward five seconds")
            Text("\(meetingTime(model.playhead)) / \(meetingTime(document.duration))")
                .font(.system(.callout, design: .monospaced)).frame(minWidth: 120, alignment: .leading)
            Slider(value: Binding(get: { model.playhead }, set: { model.seek($0) }), in: 0...max(0.01, document.duration))
                .accessibilityLabel("Playback position").frame(minWidth: 90)
            Divider().frame(height: 18)
            Button { model.zoom = max(1, model.zoom / 1.6) } label: { Image(systemName: "minus.magnifyingglass") }
                .disabled(model.zoom <= 1).accessibilityLabel("Zoom out")
            Text(String(format: "%.1f×", model.zoom)).font(.caption.monospaced()).lineLimit(1).frame(width: 42)
            Button { model.zoom = min(32, model.zoom * 1.6) } label: { Image(systemName: "plus.magnifyingglass") }
                .disabled(model.zoom >= 32).accessibilityLabel("Zoom in")
            Button("Fit") { model.zoom = 1 }
        }.padding(.horizontal, MeetingStyle.inset).padding(.vertical, 10)
    }

    private func correctionBar(_ document: MeetingDocument) -> some View {
        HStack(spacing: 8) {
            Button { model.undo() } label: { Image(systemName: "arrow.uturn.backward") }
                .accessibilityLabel("Undo edit").disabled(model.undoCount == 0 || model.isBusy)
            Button { model.redo() } label: { Image(systemName: "arrow.uturn.forward") }
                .accessibilityLabel("Redo edit").disabled(model.redoCount == 0 || model.isBusy)
            Divider().frame(height: 18)
            if let selected = model.selected {
                Menu("Assign speaker") {
                    ForEach(Array(document.speakers.enumerated()), id: \.element.id) { index, speaker in
                        Button("\(index + 1)  \(speaker.name)") { model.assign([speaker.id]) }
                    }
                    Divider()
                    Button("Other / background") { model.assign([]) }
                }
                Menu("Overlap") {
                    ForEach(document.speakers) { speaker in
                        Button((selected.speakerIDs.contains(speaker.id) ? "✓ " : "") + speaker.name) {
                            var ids = selected.speakerIDs
                            if ids.contains(speaker.id) { ids.removeAll { $0 == speaker.id } } else { ids.append(speaker.id) }
                            model.assign(ids)
                        }
                    }
                }.help("Select every participant audible in this segment. Playback remains the original mix.")
                Button("Split at playhead") { model.split() }.disabled(!model.canSplit)
                Button(selected.isConfirmed ? "Unlock" : "Confirm", systemImage: selected.isConfirmed ? "lock.open" : "checkmark") {
                    if selected.isConfirmed { model.unlock() } else { model.confirm() }
                }
                Menu("Boundaries") {
                    Button("Start at playhead") { model.setBounds(start: model.playhead, end: selected.end) }
                        .disabled(model.playhead >= selected.end)
                    Button("End at playhead") { model.setBounds(start: selected.start, end: model.playhead) }
                        .disabled(model.playhead <= selected.start)
                }
            } else {
                Text("Select a segment to correct its speaker").font(.callout).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            Button("Next uncertain", systemImage: "arrow.right") { model.nextUncertain() }
                .disabled(!model.hasAnalysis)
        }.controlSize(.small).padding(.horizontal, MeetingStyle.inset).padding(.vertical, 10)
            .disabled(model.isBusy)
    }

    private func transcript(_ document: MeetingDocument) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Transcript").font(.headline)
                Text("\(document.regions.filter(\.isConfirmed).count) of \(document.regions.count) segments confirmed")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Text("Space  Play / pause     1–9  Assign speaker").font(.caption).foregroundStyle(.secondary)
            }.padding(.horizontal, MeetingStyle.inset).padding(.vertical, 10)
            if document.regions.isEmpty {
                Text(model.isBusy ? "Your timeline and transcript will appear here when local analysis finishes." : "Choose the participants and transcribe to create speaker lanes. You can listen to the original recording now.")
                    .foregroundStyle(.secondary).padding(MeetingStyle.inset).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 0) {
                            ForEach(document.regions) { region in
                                transcriptRow(region, document: document).id(region.id)
                            }
                        }
                    }
                    .onChange(of: model.selectedID) { _, id in if let id { proxy.scrollTo(id, anchor: .center) } }
                }
            }
        }.frame(minHeight: 110, maxHeight: .infinity)
    }

    private func transcriptRow(_ region: MeetingRegion, document: MeetingDocument) -> some View {
        Button { model.select(region.id) } label: {
            HStack(alignment: .top, spacing: 12) {
                Text(meetingTime(region.start)).font(.system(.caption, design: .monospaced)).foregroundStyle(.secondary).frame(width: 52, alignment: .leading)
                Text(region.speakerIDs.compactMap { id in document.speakers.first { $0.id == id }?.name }.joined(separator: " + ").nonEmpty ?? "Other")
                    .font(.callout.weight(.medium)).frame(width: 135, alignment: .leading)
                Text(document.text(for: region).nonEmpty ?? "[No recognized words]")
                    .font(.body).frame(maxWidth: .infinity, alignment: .leading).multilineTextAlignment(.leading)
                Image(systemName: region.isConfirmed ? "checkmark" : (region.isUncertain ? "questionmark" : "circle.dotted"))
                    .foregroundStyle(.secondary).frame(width: 16)
                    .accessibilityLabel(region.isConfirmed ? "Confirmed" : region.isUncertain ? "Uncertain" : "Automatic")
            }.padding(.horizontal, MeetingStyle.inset).padding(.vertical, 10)
                .background(model.selectedID == region.id ? Color.accentColor.opacity(0.12) : Color.clear)
                .contentShape(Rectangle())
        }.buttonStyle(.plain)
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let error = model.error {
                HStack(alignment: .top) {
                    Label(error, systemImage: "exclamationmark.triangle").font(.callout).textSelection(.enabled)
                    Spacer()
                    Button("Retry save") { model.persist() }
                    Button("Dismiss") { model.error = nil }
                }.foregroundStyle(.red)
            }
            HStack(spacing: 10) {
                if model.isBusy { ProgressView().controlSize(.small) }
                Text(model.status).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                Spacer()
                if model.isBusy { Button("Cancel") { model.cancel() }.controlSize(.small) }
                else if model.document != nil {
                    Button("Show files") { model.revealFiles() }.controlSize(.small)
                }
            }
            if model.isBusy && model.progress > 0 { ProgressView(value: model.progress).progressViewStyle(.linear) }
        }.padding(.horizontal, MeetingStyle.inset).padding(.vertical, 10)
    }
}

/// Keep an editable draft so spaces and temporarily empty names survive typing.
/// Nonempty changes still autosave, including when a window closes mid-edit.
private struct MeetingSpeakerNameField: View {
    @ObservedObject var model: MeetingEditorModel
    let documentID: String
    let speaker: MeetingSpeaker
    let number: Int
    @State private var draft: String
    @FocusState private var isEditing: Bool

    init(model: MeetingEditorModel, documentID: String, speaker: MeetingSpeaker, number: Int) {
        self.model = model
        self.documentID = documentID
        self.speaker = speaker
        self.number = number
        _draft = State(initialValue: speaker.name)
    }

    var body: some View {
        TextField("Speaker name", text: $draft)
            .textFieldStyle(.roundedBorder)
            .frame(width: 112)
            .accessibilityLabel("Name for speaker \(number)")
            .focused($isEditing)
            .disabled(model.isBusy)
            .onChange(of: draft) { _, value in
                guard isEditing, model.document?.id == documentID else { return }
                let name = value.trimmingCharacters(in: .whitespacesAndNewlines)
                if !name.isEmpty, name != model.document?.speakers.first(where: { $0.id == speaker.id })?.name {
                    model.rename(speaker.id, name)
                }
            }
            .onSubmit { commit() }
            .onChange(of: isEditing) { _, editing in
                if !editing { commit() }
            }
            .onChange(of: speaker.name) { _, name in
                if !isEditing { draft = name }
            }
            .onChange(of: model.isBusy) { _, busy in
                if busy && isEditing { commit(); isEditing = false }
            }
    }

    private func commit() {
        guard model.document?.id == documentID,
              let current = model.document?.speakers.first(where: { $0.id == speaker.id }) else { return }
        let name = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        if name.isEmpty {
            draft = current.name
        } else {
            if name != current.name { model.rename(speaker.id, name) }
            draft = name
        }
    }
}

private extension String { var nonEmpty: String? { isEmpty ? nil : self } }
