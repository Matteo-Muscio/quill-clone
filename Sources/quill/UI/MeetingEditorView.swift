import SwiftUI
import UniformTypeIdentifiers

private enum MeetingStyle {
    static let inset: CGFloat = 20
    static let colors: [Color] = [.blue, .orange, .teal, .purple, .pink, .indigo, .brown, .cyan, .green]
}

struct MeetingEditorView: View {
    @ObservedObject var model: MeetingEditorModel
    @ObservedObject private var notesModelManager = NotesModelManager.shared
    @State private var dropTarget = false
    @State private var isReading = false
    @State private var showingAddSpeaker = false
    @State private var newSpeakerName = ""
    @State private var assignAllUnknown = false
    @State private var showingResetText = false

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if let document = model.document {
                if isReading { reading(document) } else { workspace(document) }
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
        .onChange(of: model.document?.id) { _, _ in isReading = false }
        .sheet(isPresented: $showingAddSpeaker) { addSpeakerSheet }
        .confirmationDialog("Replace your wording corrections?", isPresented: $showingResetText) {
            Button("Reset wording and transcribe again", role: .destructive) { model.resetTextCorrections(); model.transcribe() }
        } message: {
            Text("A new transcription starts from the original audio. Speaker corrections remain protected, but your wording corrections will be removed. You can undo this change.")
        }
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
                if let document = model.document {
                    MeetingTitleField(model: model, document: document).id(document.id)
                } else {
                    Text("Recorded meetings").font(.system(size: 20, weight: .semibold))
                        .accessibilityAddTraits(.isHeader)
                }
                Text(model.document.map { "\(meetingTime($0.duration)) · Original recording preserved" } ?? "Record on your phone. Review on your Mac.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            Spacer(minLength: 12)
            if model.hasAnalysis {
                Button(isReading ? "Return to editor" : "View transcript", systemImage: isReading ? "waveform" : "doc.text") {
                    model.pause()
                    if !isReading { model.selectedID = nil }
                    isReading.toggle()
                }
            }
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
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                MeetingOpeningDemo().frame(height: 120).accessibilityHidden(true)
                Text("Bring your conversation into focus.").font(.system(size: 26, weight: .medium))
                Text("Drop an iPhone Voice Memo here. Quill transcribes it on this Mac and builds a timeline you can review, rename, and correct.")
                    .font(.body).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 16) {
                    Button("Choose a recording…", systemImage: "square.and.arrow.down") { model.chooseRecording() }
                    Label("Audio stays on this Mac", systemImage: "lock.shield").font(.callout).foregroundStyle(.secondary)
                }
                Divider().padding(.top, 4)
                HStack {
                    Text("Recent meetings").font(.headline)
                    Spacer()
                    Text("Saved on this Mac").font(.caption).foregroundStyle(.secondary)
                }
                if model.recent.isEmpty {
                    Text("Your imported recordings will appear here.").foregroundStyle(.secondary).padding(.vertical, 8)
                } else {
                    VStack(spacing: 0) {
                        ForEach(model.recent.prefix(6)) { session in
                            Button { model.open(session.id) } label: {
                                HStack(spacing: 14) {
                                    Image(systemName: "waveform").foregroundStyle(.secondary)
                                    Text(session.title).font(.body.weight(.medium)).lineLimit(1)
                                    Spacer()
                                    Text(meetingTime(session.duration)).font(.callout.monospaced()).foregroundStyle(.secondary)
                                    Text(session.updatedAt, style: .date).font(.callout).foregroundStyle(.secondary)
                                    Image(systemName: "arrow.up.right").font(.caption).foregroundStyle(.secondary)
                                }.padding(.vertical, 11).contentShape(Rectangle())
                            }.buttonStyle(.plain)
                            Divider()
                        }
                    }
                }
            }.frame(maxWidth: 800, alignment: .leading).padding(.horizontal, 40).padding(.vertical, 24)
                .frame(maxWidth: .infinity)
        }
    }

    private func workspace(_ document: MeetingDocument) -> some View {
        VStack(spacing: 0) {
            participantBar(document)
            Divider()
            transport(document)
            MeetingTimeline(model: model, onCreateSpeaker: { beginAddingSpeaker() })
                .frame(minHeight: 190, idealHeight: min(400, CGFloat(document.speakers.count + 1) * 52 + 116), maxHeight: min(400, CGFloat(document.speakers.count + 1) * 52 + 116))
                .layoutPriority(1)
            Divider()
            correctionBar(document)
            Divider()
            transcript(document)
        }
    }

    private func participantBar(_ document: MeetingDocument) -> some View {
        HStack(alignment: .center, spacing: 12) {
            Picker("Participants", selection: Binding(get: { model.participantCount }, set: { model.participantCount = $0; model.configureSpeakers() })) {
                Text("Automatic").tag(0)
                ForEach(1...12, id: \.self) { count in Text("\(count) participants").tag(count) }
            }.frame(width: 220)
                .help("Optional guidance for the next analysis. Changing this does not relabel an existing transcript.")
                .disabled(model.isBusy)
            Button("Speaker", systemImage: "plus") { beginAddingSpeaker() }.disabled(model.isBusy).accessibilityLabel("Add speaker")
            Text("Double-click a lane name to rename it").font(.caption).foregroundStyle(.secondary).lineLimit(1)
            Spacer(minLength: 0)
            if !model.hasAnalysis {
                Button("Transcribe", systemImage: "text.bubble") { model.transcribe() }
                    .disabled(model.isBusy || document.duration <= 0)
            } else {
                Menu("Analyze") {
                    Button("Refine remaining audio") { model.refine() }
                        .disabled(!document.regions.contains(where: { $0.isConfirmed }))
                    Button("Transcribe again") {
                        if document.hasTextCorrections { showingResetText = true } else { model.transcribe() }
                    }
                }.disabled(model.isBusy)
            }
        }.padding(.horizontal, MeetingStyle.inset).padding(.vertical, 10)
    }

    private func beginAddingSpeaker() {
        newSpeakerName = ""
        assignAllUnknown = false
        showingAddSpeaker = true
    }

    private var addSpeakerSheet: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Add a speaker").font(.title2.weight(.semibold))
            TextField("Name", text: $newSpeakerName).textFieldStyle(.roundedBorder)
                .accessibilityLabel("New speaker name")
            Text("Unassigned audio may contain several people or background voices.")
                .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Picker("Assign audio", selection: $assignAllUnknown) {
                Text(model.selected?.speakerIDs.isEmpty == true ? "Selected unassigned segment" : "Create an empty speaker lane").tag(false)
                Text("All unassigned segments").tag(true)
            }.pickerStyle(.radioGroup)
            HStack {
                Spacer()
                Button("Cancel") { showingAddSpeaker = false }.keyboardShortcut(.cancelAction)
                Button("Add speaker") {
                    model.addSpeaker(name: newSpeakerName, assignAllUnknown: assignAllUnknown)
                    showingAddSpeaker = false
                }.keyboardShortcut(.defaultAction)
            }
        }.padding(24).frame(width: 410)
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
                .disabled(model.zoom >= 32).accessibilityLabel("Zoom in").help("Zoom in. You can also pinch or Option-scroll over the timeline.")
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
                    Button("Unassigned / background") { model.assign([]) }
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
                Text("Double-click wording to edit · Space to play · 1–9 assign").font(.caption).foregroundStyle(.secondary)
            }.padding(.horizontal, MeetingStyle.inset).padding(.vertical, 10)
            if document.regions.isEmpty {
                Text(model.isBusy ? "Your timeline and transcript will appear here when local analysis finishes." : "Quill analyzes imported recordings automatically. If analysis was cancelled, choose Transcribe to retry.")
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
        MeetingTranscriptRow(model: model, document: document, region: region)
            .id(document.id + region.id)
    }

    private func reading(_ document: MeetingDocument) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Label(document.reviewedAt == nil ? "Draft transcript" : "Reviewed", systemImage: document.reviewedAt == nil ? "doc.text" : "checkmark")
                    .font(.callout.weight(.medium))
                Button(document.reviewedAt == nil ? "Mark reviewed" : "Mark as draft") { model.markReviewed(document.reviewedAt == nil) }
                    .disabled(model.isBusy)
                Spacer()
                Button("Copy", systemImage: "doc.on.doc") { model.copyTranscript() }
                Button("Export…", systemImage: "square.and.arrow.up") { model.exportTranscript() }
            }.padding(.horizontal, MeetingStyle.inset).padding(.vertical, 12)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    VStack(alignment: .leading, spacing: 12) {
                        HStack {
                            Text("Meeting notes").font(.title3.weight(.semibold))
                            Spacer()
                            Text(notesModelManager.activeModel.displayName).font(.caption).foregroundStyle(.secondary)
                            if notesModelManager.state(for: notesModelManager.activeModel) == .active {
                                Button(document.notes == nil ? "Generate notes" : "Regenerate notes", systemImage: "text.badge.star") { model.generateNotes() }
                                    .disabled(model.isBusy || !model.canGenerateNotes)
                            } else {
                                Button("Set up notes model…", systemImage: "arrow.down.circle") { model.onOpenNotesSettings?() }
                                    .disabled(model.isBusy || model.onOpenNotesSettings == nil)
                            }
                        }
                        if document.notes != nil {
                            if document.notesAreStale {
                                Label("The transcript changed since these notes were generated. Regenerate to update them.", systemImage: "arrow.triangle.2.circlepath")
                                    .font(.callout).foregroundStyle(.secondary)
                            }
                            MeetingNotesEditor(model: model).id(document.id)
                        } else {
                            Text("Generate a title, summary, key takeaways, and action items from the corrected transcript using a local model. You can edit the result.")
                                .foregroundStyle(.secondary)
                            if notesModelManager.state(for: notesModelManager.activeModel) != .active {
                                Text("Set up a meeting notes model in Quill Settings to generate notes.").font(.callout).foregroundStyle(.secondary)
                            }
                        }
                    }
                    Divider()
                    Text("Full transcript").font(.title3.weight(.semibold))
                    LazyVStack(alignment: .leading, spacing: 18) {
                        ForEach(document.transcriptParagraphs) { region in
                            VStack(alignment: .leading, spacing: 5) {
                                HStack(spacing: 10) {
                                    Text(region.speakerIDs.compactMap { id in document.speakers.first { $0.id == id }?.name }.joined(separator: " + ").nonEmpty ?? "Unassigned")
                                        .font(.callout.weight(.semibold))
                                    Button(meetingTime(region.start)) {
                                        model.select(region.id); isReading = false
                                    }.buttonStyle(.plain).font(.caption.monospaced()).foregroundStyle(.secondary)
                                }
                                Text(region.text)
                                    .textSelection(.enabled).lineSpacing(4)
                            }.frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                }.frame(maxWidth: 820, alignment: .leading).padding(28).frame(maxWidth: .infinity)
            }
        }
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
                if model.status != "Saved on this Mac" {
                    Text(model.status).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                }
                Spacer()
                if model.document != nil {
                    Label(model.hasUnsavedChanges ? "Changes not saved" : "Saved on this Mac", systemImage: model.hasUnsavedChanges ? "exclamationmark.circle" : "checkmark")
                        .font(.caption).foregroundStyle(model.hasUnsavedChanges ? Color.red : Color.secondary)
                }
                if model.isBusy { Button("Cancel") { model.cancel() }.controlSize(.small) }
                else if model.document != nil {
                    Button("Show files") { model.revealFiles() }.controlSize(.small)
                }
            }
            if model.isBusy && model.progress > 0 { ProgressView(value: model.progress).progressViewStyle(.linear) }
        }.padding(.horizontal, MeetingStyle.inset).padding(.vertical, 10)
    }
}

private extension String { var nonEmpty: String? { isEmpty ? nil : self } }

private struct MeetingTitleField: View {
    @ObservedObject var model: MeetingEditorModel
    let document: MeetingDocument
    @State private var editing = false
    @State private var draft = ""
    @FocusState private var focused: Bool

    var body: some View {
        Group {
            if editing {
                TextField("Meeting title", text: $draft)
                    .textFieldStyle(.plain).focused($focused)
                    .onChange(of: draft) { _, value in
                        guard model.document?.id == document.id else { return }
                        let title = value.trimmingCharacters(in: .whitespacesAndNewlines)
                        if !title.isEmpty { model.renameTitle(title) }
                    }
                    .onSubmit { editing = false }
                    .onChange(of: focused) { _, value in if !value { editing = false } }
                    .onExitCommand { editing = false }
            } else {
                Text(document.title).lineLimit(1)
                    .onTapGesture(count: 2) { startEditing() }
                    .contextMenu { Button("Rename meeting") { startEditing() } }
                    .help("Double-click to rename this meeting")
                    .accessibilityAction(named: "Rename meeting") { startEditing() }
            }
        }.font(.system(size: 20, weight: .semibold))
            .accessibilityAddTraits(.isHeader).disabled(model.isBusy)
    }

    private func startEditing() {
        draft = document.title; editing = true; focused = true
    }
}

private struct MeetingTranscriptRow: View {
    @ObservedObject var model: MeetingEditorModel
    let document: MeetingDocument
    let region: MeetingRegion
    @State private var editing = false
    @State private var draft = ""
    @State private var showingOriginal = false
    @FocusState private var focused: Bool

    private var speakerName: String {
        region.speakerIDs.compactMap { id in document.speakers.first { $0.id == id }?.name }.joined(separator: " + ").nonEmpty ?? "Unassigned"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(alignment: .top, spacing: 12) {
                Text(meetingTime(region.start)).font(.system(.caption, design: .monospaced)).foregroundStyle(.secondary).frame(width: 52, alignment: .leading)
                Text(speakerName).font(.callout.weight(.medium)).frame(width: 135, alignment: .leading)
                if editing {
                    VStack(alignment: .leading, spacing: 7) {
                        TextEditor(text: $draft).font(.body).focused($focused)
                            .frame(minHeight: 54, maxHeight: 120)
                            .overlay(Rectangle().stroke(Color.accentColor.opacity(0.5), lineWidth: 1))
                            .accessibilityLabel("Edit transcript wording at \(meetingTime(region.start))")
                            .onChange(of: draft) { _, value in
                                if model.document?.id == document.id { model.updateText(regionID: region.id, text: value) }
                            }
                            .onChange(of: focused) { _, value in if !value { editing = false } }
                            .onExitCommand { editing = false }
                        HStack {
                            Text("Wording changes do not confirm the speaker.").font(.caption).foregroundStyle(.secondary)
                            Button(showingOriginal ? "Hide original" : "Original recognition") { showingOriginal.toggle() }.controlSize(.small)
                            Spacer()
                            Button("Done") { editing = false }.controlSize(.small)
                        }
                    }
                } else {
                    Text(document.text(for: region).nonEmpty ?? "[No recognized words]")
                        .font(.body).frame(maxWidth: .infinity, alignment: .leading)
                        .multilineTextAlignment(.leading)
                }
                Image(systemName: region.isConfirmed ? "checkmark" : (region.isUncertain ? "questionmark" : "circle.dotted"))
                    .foregroundStyle(.secondary).frame(width: 16)
                    .accessibilityLabel(region.isConfirmed ? "Confirmed speaker" : region.isUncertain ? "Uncertain speaker" : "Automatic speaker")
            }
            if showingOriginal {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Original recognition").font(.caption.weight(.medium))
                    Text(document.originalText(for: region).nonEmpty ?? "[No recognized words]").font(.callout).textSelection(.enabled)
                }.foregroundStyle(.secondary).padding(.leading, 211)
            }
        }
        .padding(.horizontal, MeetingStyle.inset).padding(.vertical, 10)
        .background(model.selectedID == region.id ? Color.accentColor.opacity(0.12) : Color.clear)
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { startEditing() }
        .onTapGesture { if !editing { model.select(region.id) } }
        .contextMenu {
            Button("Edit wording") { startEditing() }.disabled(model.isBusy)
            Button(showingOriginal ? "Hide original recognition" : "Show original recognition") { showingOriginal.toggle() }
            Button("Play from here") { model.select(region.id); if !model.isPlaying { model.togglePlayback() } }
        }
        .accessibilityElement(children: .contain)
        .accessibilityAction(named: "Select segment") { model.select(region.id) }
        .accessibilityAction(named: "Edit wording") { startEditing() }
        .onChange(of: model.isBusy) { _, busy in if busy { editing = false } }
    }

    private func startEditing() {
        guard !model.isBusy else { return }
        model.select(region.id, seek: false)
        draft = document.text(for: region); editing = true; focused = true
    }
}

private struct MeetingNotesEditor: View {
    @ObservedObject var model: MeetingEditorModel

    var body: some View {
        if let notes = model.document?.notes {
            VStack(alignment: .leading, spacing: 16) {
                HStack {
                    TextField("Suggested title", text: Binding(get: { model.document?.notes?.title ?? "" }, set: { value in model.updateNotes { $0.title = value } }))
                        .textFieldStyle(.roundedBorder).font(.headline).accessibilityLabel("Meeting notes title")
                    Button("Use as meeting title") { model.renameTitle(notes.title) }
                        .disabled(notes.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
                notesField("Summary", text: Binding(get: { model.document?.notes?.summary ?? "" }, set: { value in model.updateNotes { $0.summary = value } }), height: 90)
                notesField("Key takeaways · one per line", text: Binding(get: { model.document?.notes?.keyTakeaways.joined(separator: "\n") ?? "" }, set: { value in model.updateNotes { $0.keyTakeaways = value.components(separatedBy: "\n") } }), height: 85)
                notesField("Action items · one per line", text: Binding(get: { model.document?.notes?.actionItems.joined(separator: "\n") ?? "" }, set: { value in model.updateNotes { $0.actionItems = value.components(separatedBy: "\n") } }), height: 85)
                Text("Generated locally with \(notes.modelID) · Review the notes against the transcript.")
                    .font(.caption).foregroundStyle(.secondary)
            }.disabled(model.isBusy)
        }
    }

    private func notesField(_ label: String, text: Binding<String>, height: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label).font(.callout.weight(.medium))
            TextEditor(text: text).font(.body).frame(minHeight: height, maxHeight: height + 50)
                .padding(5).background(Color(nsColor: .textBackgroundColor))
                .overlay(Rectangle().stroke(Color(nsColor: .separatorColor), lineWidth: 0.5))
                .accessibilityLabel(label)
        }
    }
}

/// A short schematic demonstrates the recording-to-lanes workflow once.
/// It is explicitly an example, and becomes a static illustration with reduced motion.
private struct MeetingOpeningDemo: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var start = Date()
    @State private var completed = false

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 30, paused: completed || reduceMotion)) { context in
            let progress = reduceMotion || completed ? 1.0 : min(1, max(0, context.date.timeIntervalSince(start) / 6))
            Canvas { graphics, size in
                let labelWidth: CGFloat = 86
                let chartWidth = max(1, size.width - labelWidth)
                let separation = min(1, max(0, (progress - 0.18) / 0.35))
                let label = Text(separation < 0.2 ? "Recording" : "Speakers").font(.caption).foregroundStyle(.secondary)
                graphics.draw(label, at: CGPoint(x: 0, y: 20), anchor: .leading)
                graphics.draw(Text("EXAMPLE").font(.system(size: 9, weight: .medium)).foregroundStyle(.secondary), at: CGPoint(x: 0, y: 101), anchor: .leading)
                for lane in 0..<3 {
                    let y = CGFloat(lane) * 32 + 24
                    var line = Path(); line.move(to: CGPoint(x: labelWidth, y: y + 15)); line.addLine(to: CGPoint(x: size.width, y: y + 15))
                    graphics.stroke(line, with: .color(.secondary.opacity(0.15)), lineWidth: 0.5)
                }
                for bar in 0..<110 {
                    let lane = (bar / 11) % 3
                    let destination = CGFloat(lane) * 32 + 24
                    let y = 55 + (destination - 55) * separation
                    let x = labelWidth + CGFloat(bar) / 110 * chartWidth
                    let height = CGFloat(3 + abs(sin(Double(bar) * 1.71) * cos(Double(bar) * 0.39)) * 19)
                    var waveform = Path(); waveform.move(to: CGPoint(x: x, y: y - height / 2)); waveform.addLine(to: CGPoint(x: x, y: y + height / 2))
                    graphics.stroke(waveform, with: .color(MeetingStyle.colors[lane].opacity(0.55 + 0.25 * separation)), lineWidth: 2)
                }
                if !completed && !reduceMotion {
                    let x = labelWidth + CGFloat(progress) * chartWidth
                    var playhead = Path(); playhead.move(to: CGPoint(x: x, y: 4)); playhead.addLine(to: CGPoint(x: x, y: 108))
                    graphics.stroke(playhead, with: .color(.primary.opacity(0.5)), lineWidth: 1)
                }
            }
        }.task {
            guard !reduceMotion else { completed = true; return }
            start = Date()
            try? await Task.sleep(for: .seconds(6))
            if !Task.isCancelled { completed = true }
        }
    }
}
