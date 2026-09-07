import AppKit
import SwiftUI

/// An annotation timeline. Horizontal positions are recording time; vertical drags
/// only change speaker attribution. Drawing is bounded to the visible time range.
struct MeetingTimeline: NSViewRepresentable {
    @ObservedObject var model: MeetingEditorModel
    var onCreateSpeaker: () -> Void = {}

    func makeNSView(context: Context) -> MeetingTimelineScrollView {
        let scroll = MeetingTimelineScrollView()
        scroll.hasHorizontalScroller = true
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        let timeline = MeetingTimelineView()
        timeline.model = model
        timeline.onCreateSpeaker = onCreateSpeaker
        timeline.setAccessibilityElement(true)
        timeline.setAccessibilityRole(.group)
        timeline.setAccessibilityLabel("Recording timeline. Use the playback slider and transcript below for keyboard review.")
        scroll.documentView = timeline
        return scroll
    }

    func updateNSView(_ scroll: MeetingTimelineScrollView, context: Context) {
        guard let timeline = scroll.documentView as? MeetingTimelineView else { return }
        timeline.model = model
        timeline.onCreateSpeaker = onCreateSpeaker
        timeline.synchronizeNameEditor()
        if let document = model.document {
            var actions = document.speakers.enumerated().map { lane, speaker in
                NSAccessibilityCustomAction(name: "Rename \(speaker.name)") { [weak timeline] in
                    guard let timeline, timeline.model?.isBusy == false else { return false }
                    timeline.beginRenaming(speaker, documentID: document.id, lane: lane)
                    return true
                }
            }
            actions.append(NSAccessibilityCustomAction(name: "Add speaker from unassigned audio") { [weak timeline] in
                guard let timeline, timeline.model?.isBusy == false else { return false }
                timeline.onCreateSpeaker()
                return true
            })
            timeline.setAccessibilityCustomActions(actions)
        }
        scroll.updateGeometry()
        let width = max(1, scroll.contentSize.width)
        timeline.needsDisplay = true
        if timeline.lastZoom != model.zoom {
            timeline.lastZoom = model.zoom
            let anchor = timeline.x(for: model.selected?.start ?? model.playhead)
            timeline.scrollToVisible(NSRect(x: max(0, anchor - 150), y: 0, width: min(width, timeline.bounds.width), height: 1))
        }
        if timeline.lastSelectedID != model.selectedID, let selected = model.selected {
            timeline.lastSelectedID = model.selectedID
            let x = timeline.x(for: selected.start)
            if x < timeline.visibleRect.minX + 150 || x > timeline.visibleRect.maxX - 20 {
                timeline.scrollToVisible(NSRect(x: max(0, x - 150), y: 0, width: min(width, timeline.bounds.width), height: 1))
            }
        }
    }
}

/// SwiftUI can update an NSViewRepresentable before AppKit assigns its viewport.
/// Recompute document geometry during native layout as well as model updates.
@MainActor
final class MeetingTimelineScrollView: NSScrollView {
    private var updatingGeometry = false

    override func layout() {
        super.layout()
        updateGeometry()
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        updateGeometry()
    }

    func updateGeometry() {
        guard !updatingGeometry, let timeline = documentView as? MeetingTimelineView,
              let model = timeline.model, contentSize.width > 0 else { return }
        updatingGeometry = true
        defer { updatingGeometry = false }
        let width = contentSize.width
        let size = NSSize(width: max(width, (width - 150) * model.zoom + 150),
                          height: max(contentSize.height, CGFloat((model.document?.speakers.count ?? 2) + 1) * 52 + 98))
        if abs(timeline.frame.width - size.width) > 0.5 || abs(timeline.frame.height - size.height) > 0.5 {
            timeline.setFrameSize(size)
            timeline.needsDisplay = true
        }
    }

    override func magnify(with event: NSEvent) {
        zoomTimeline(with: event, factor: Double(1 + event.magnification))
    }

    override func scrollWheel(with event: NSEvent) {
        if event.modifierFlags.contains(.option) {
            zoomTimeline(with: event, factor: exp(Double(event.scrollingDeltaY) * 0.015))
        } else {
            super.scrollWheel(with: event)
        }
    }

    func zoomTimeline(with event: NSEvent, factor: Double) {
        guard let timeline = documentView as? MeetingTimelineView, let model = timeline.model,
              factor.isFinite, factor > 0 else { return }
        let point = timeline.convert(event.locationInWindow, from: nil)
        let offset = max(150, point.x - contentView.bounds.minX)
        let anchorTime = timeline.time(for: contentView.bounds.minX + offset)
        let zoom = min(32, max(1, model.zoom * factor))
        guard abs(zoom - model.zoom) > 0.0001 else { return }
        // Prevent the subsequent SwiftUI update from substituting a selection anchor.
        timeline.lastZoom = zoom
        model.zoom = zoom
        updateGeometry()
        let target = max(0, min(timeline.bounds.width - contentSize.width, timeline.x(for: anchorTime) - offset))
        contentView.scroll(to: NSPoint(x: target, y: contentView.bounds.minY))
        reflectScrolledClipView(contentView)
    }

    override func reflectScrolledClipView(_ clipView: NSClipView) {
        super.reflectScrolledClipView(clipView)
        documentView?.needsDisplay = true
    }
}

@MainActor
final class MeetingTimelineView: NSView, NSTextFieldDelegate {
    weak var model: MeetingEditorModel?
    var onCreateSpeaker: () -> Void = {}
    private var nameField: NSTextField?
    private var editingSpeakerID: String?
    private var editingDocumentID: String?
    private var startingNameEdit = false
    var lastSelectedID: String?
    var lastZoom = 1.0
    private var isScrubbing = false
    private let labelWidth: CGFloat = 150
    private let laneHeight: CGFloat = 52
    private let trackTop: CGFloat = 98
    private var dragOrigin: NSPoint?
    private var draggingRegion: MeetingRegion?
    private var resizingStart: Bool?
    private var dragPoint: NSPoint?
    private let colors: [NSColor] = [.systemBlue, .systemOrange, .systemTeal, .systemPurple, .systemPink, .systemIndigo, .systemBrown, .systemCyan, .systemGreen]
    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }

    func x(for time: Double) -> CGFloat {
        labelWidth + CGFloat(time / max(0.01, model?.document?.duration ?? 1)) * (bounds.width - labelWidth - 16)
    }
    fileprivate func time(for x: CGFloat) -> Double {
        min(model?.document?.duration ?? 0, max(0, Double((x - labelWidth) / max(1, bounds.width - labelWidth - 16)) * (model?.document?.duration ?? 1)))
    }
    private func row(for point: NSPoint) -> Int { Int(floor((point.y - trackTop) / laneHeight)) }
    private func regionRect(_ region: MeetingRegion, lane: Int) -> NSRect {
        NSRect(x: x(for: region.start), y: trackTop + CGFloat(lane) * laneHeight + 5,
               width: max(3, x(for: region.end) - x(for: region.start)), height: laneHeight - 10)
    }
    private func text(_ text: String, rect: NSRect, color: NSColor = .secondaryLabelColor, size: CGFloat = 11, bold: Bool = false, mono: Bool = false) {
        let style = NSMutableParagraphStyle()
        style.lineBreakMode = .byTruncatingTail
        (text as NSString).draw(in: rect, withAttributes: [.font: mono ? NSFont.monospacedDigitSystemFont(ofSize: size, weight: .regular) : NSFont.systemFont(ofSize: size, weight: bold ? .medium : .regular), .foregroundColor: color, .paragraphStyle: style])
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.controlBackgroundColor.setFill(); dirtyRect.fill()
        guard let model, let document = model.document else { return }
        let chart = NSRect(x: labelWidth, y: 0, width: bounds.width - labelWidth, height: bounds.height)
        NSGraphicsContext.saveGraphicsState()
        chart.clip()
        let visible = visibleRect.intersection(chart)
        let start = time(for: visible.minX)
        let end = time(for: visible.maxX)
        let rawStep = max(1, (end - start) / max(1, Double(visible.width / 90)))
        let steps: [Double] = [1, 2, 5, 10, 15, 30, 60, 120, 300, 600, 1800, 3600]
        let step = steps.first(where: { $0 >= rawStep }) ?? 7200
        var tick = floor(start / step) * step
        let grid = NSBezierPath()
        while tick <= end {
            let tickX = x(for: tick)
            grid.move(to: NSPoint(x: tickX, y: 25)); grid.line(to: NSPoint(x: tickX, y: bounds.height))
            text(meetingTime(tick), rect: NSRect(x: tickX + 4, y: 7, width: 75, height: 16), mono: true)
            tick += step
        }
        NSColor.separatorColor.withAlphaComponent(0.4).setStroke(); grid.lineWidth = 0.5; grid.stroke()
        drawWaveform(document, visible: visible)

        for lane in 0...document.speakers.count {
            let laneY = trackTop + CGFloat(lane) * laneHeight
            NSColor.separatorColor.setFill(); NSRect(x: visible.minX, y: laneY, width: visible.width, height: 0.5).fill()
            let speaker = lane < document.speakers.count ? document.speakers[lane].id : nil
            for region in document.regions where region.end >= start && region.start <= end {
                let belongs = speaker.map { region.speakerIDs.contains($0) } ?? region.speakerIDs.isEmpty
                guard belongs else { continue }
                let rect = regionRect(region, lane: lane)
                let color = speaker == nil ? NSColor.secondaryLabelColor : colors[lane % colors.count]
                let selected = model.selectedID == region.id
                color.withAlphaComponent(selected ? 0.32 : 0.16).setFill()
                NSBezierPath(roundedRect: rect, xRadius: 3, yRadius: 3).fill()
                color.withAlphaComponent(selected ? 1 : 0.65).setStroke()
                let outline = NSBezierPath(roundedRect: rect.insetBy(dx: 0.5, dy: 0.5), xRadius: 3, yRadius: 3)
                outline.lineWidth = selected ? 2 : 1
                if region.isUncertain && !region.isConfirmed { outline.setLineDash([3, 3], count: 2, phase: 0) }
                outline.stroke()
                if rect.width > 34 {
                    let marker = region.isConfirmed ? "✓ " : region.isUncertain ? "? " : ""
                    text(marker + document.text(for: region), rect: rect.insetBy(dx: 7, dy: 11), color: .labelColor)
                }
                if selected && rect.width > 16 {
                    color.setFill()
                    NSRect(x: rect.minX + 2, y: rect.midY - 6, width: 2, height: 12).fill()
                    NSRect(x: rect.maxX - 4, y: rect.midY - 6, width: 2, height: 12).fill()
                }
            }
        }
        if let point = dragPoint, let region = draggingRegion {
            if resizingStart != nil {
                let line = NSBezierPath(); line.move(to: NSPoint(x: point.x, y: trackTop)); line.line(to: NSPoint(x: point.x, y: bounds.height))
                NSColor.controlAccentColor.setStroke(); line.lineWidth = 2; line.stroke()
            } else {
                let lane = max(0, min(document.speakers.count, row(for: point)))
                let rect = regionRect(region, lane: lane)
                NSColor.controlAccentColor.withAlphaComponent(0.2).setFill(); rect.fill()
                NSColor.controlAccentColor.setStroke(); NSBezierPath(rect: rect).stroke()
            }
        }
        let playX = x(for: model.playhead)
        let playhead = NSBezierPath(); playhead.move(to: NSPoint(x: playX, y: 24)); playhead.line(to: NSPoint(x: playX, y: bounds.height))
        NSColor.labelColor.setStroke(); playhead.lineWidth = 1.5; playhead.stroke()
        let marker = NSBezierPath(); marker.move(to: NSPoint(x: playX - 4, y: 23)); marker.line(to: NSPoint(x: playX + 4, y: 23)); marker.line(to: NSPoint(x: playX, y: 29)); marker.close()
        NSColor.labelColor.setFill(); marker.fill()
        NSGraphicsContext.restoreGraphicsState()
        // Labels remain pinned while the audio scrolls horizontally.
        let labelX = visibleRect.minX
        NSColor.windowBackgroundColor.setFill(); NSRect(x: labelX, y: 0, width: labelWidth, height: bounds.height).fill()
        text("ORIGINAL AUDIO", rect: NSRect(x: labelX + 16, y: 45, width: 126, height: 18), size: 10, bold: true)
        text("Shared recording", rect: NSRect(x: labelX + 16, y: 62, width: 126, height: 16), size: 10)
        for lane in 0...document.speakers.count {
            let laneY = trackTop + CGFloat(lane) * laneHeight
            NSColor.separatorColor.setFill(); NSRect(x: labelX, y: laneY, width: labelWidth, height: 0.5).fill()
            let title = lane < document.speakers.count ? "\(lane + 1)  \(document.speakers[lane].name)" : "Unassigned"
            text(title, rect: NSRect(x: labelX + 16, y: laneY + 16, width: 126, height: 20), color: .labelColor, size: 11, bold: true)
        }
        NSColor.separatorColor.setFill(); NSRect(x: labelX + labelWidth - 1, y: 0, width: 1, height: bounds.height).fill()
        if let id = editingSpeakerID, let field = nameField,
           let lane = document.speakers.firstIndex(where: { $0.id == id }) {
            field.frame.origin = NSPoint(x: labelX + 12, y: trackTop + CGFloat(lane) * laneHeight + 12)
        }
    }

    private func drawWaveform(_ document: MeetingDocument, visible: NSRect) {
        guard !document.waveform.isEmpty else { return }
        let count = document.waveform.count
        let lower = max(0, Int(time(for: visible.minX) / max(0.01, document.duration) * Double(count)))
        let upper = min(count, Int(time(for: visible.maxX) / max(0.01, document.duration) * Double(count)) + 1)
        guard lower < upper else { return }
        let path = NSBezierPath()
        for index in lower..<upper {
            let pointX = x(for: Double(index) / Double(count) * document.duration)
            let height = max(1, CGFloat(document.waveform[index]) * 27)
            path.move(to: NSPoint(x: pointX, y: 62 - height)); path.line(to: NSPoint(x: pointX, y: 62 + height))
        }
        NSColor.secondaryLabelColor.withAlphaComponent(0.85).setStroke(); path.lineWidth = 1; path.stroke()
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        guard let model, let document = model.document else { return }
        let point = convert(event.locationInWindow, from: nil)
        let lane = row(for: point)
        if point.x <= visibleRect.minX + labelWidth {
            if event.clickCount == 2, !model.isBusy, lane >= 0, lane <= document.speakers.count {
                if lane == document.speakers.count { onCreateSpeaker() }
                else { beginRenaming(document.speakers[lane], documentID: document.id, lane: lane) }
            }
            return
        }
        if lane >= 0 && lane <= document.speakers.count,
           let hit = document.regions.last(where: { region in
               let belongs = lane == document.speakers.count ? region.speakerIDs.isEmpty : region.speakerIDs.contains(document.speakers[lane].id)
               return belongs && regionRect(region, lane: lane).insetBy(dx: -2, dy: 0).contains(point)
           }) {
            let wasSelected = model.selectedID == hit.id
            model.select(hit.id, seek: false)
            model.seek(time(for: point.x))
            if !model.isBusy {
                draggingRegion = hit; dragOrigin = point
                let rect = regionRect(hit, lane: lane)
                if wasSelected && rect.width >= 18 {
                    if abs(point.x - rect.minX) < 6 { resizingStart = true }
                    else if abs(point.x - rect.maxX) < 6 { resizingStart = false }
                }
            }
            if event.clickCount == 2 { model.seek(hit.start); if !model.isPlaying { model.togglePlayback() } }
        } else {
            isScrubbing = true
            model.seek(time(for: point.x))
        }
        needsDisplay = true
    }
    override func mouseDragged(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if isScrubbing { model?.seek(time(for: point.x)); needsDisplay = true; return }
        guard let origin = dragOrigin else { return }
        if abs(point.y - origin.y) > 4 || (resizingStart != nil && abs(point.x - origin.x) > 3) { dragPoint = point; needsDisplay = true }
    }
    override func mouseUp(with event: NSEvent) {
        defer { isScrubbing = false; dragOrigin = nil; dragPoint = nil; draggingRegion = nil; resizingStart = nil; needsDisplay = true }
        guard let model, let document = model.document, let region = draggingRegion, let point = dragPoint else { return }
        if let resizingStart {
            model.setBounds(start: resizingStart ? time(for: point.x) : region.start, end: resizingStart ? region.end : time(for: point.x))
        } else {
            let lane = max(0, min(document.speakers.count, row(for: point)))
            model.assign(lane == document.speakers.count ? [] : [document.speakers[lane].id])
        }
    }
    override func magnify(with event: NSEvent) {
        (enclosingScrollView as? MeetingTimelineScrollView)?.zoomTimeline(with: event, factor: Double(1 + event.magnification))
    }

    fileprivate func synchronizeNameEditor() {
        if editingDocumentID != model?.document?.id || model?.isBusy == true || model?.isExternallyLocked == true {
            finishRenaming()
        }
    }

    fileprivate func beginRenaming(_ speaker: MeetingSpeaker, documentID: String, lane: Int) {
        finishRenaming()
        editingSpeakerID = speaker.id
        editingDocumentID = documentID
        let field = NSTextField(frame: NSRect(x: visibleRect.minX + 12, y: trackTop + CGFloat(lane) * laneHeight + 12, width: 128, height: 26))
        field.stringValue = speaker.name
        field.font = .systemFont(ofSize: 12, weight: .medium)
        field.isEditable = true
        field.isSelectable = true
        field.delegate = self
        field.setAccessibilityLabel("Speaker name")
        addSubview(field)
        nameField = field
        setAccessibilityChildren([field])
        // selectText performs the field-editor handoff itself. Doing a separate
        // makeFirstResponder first can end the just-started edit synchronously.
        startingNameEdit = true
        field.selectText(nil)
        startingNameEdit = false
        needsDisplay = true
        NSAccessibility.post(element: self, notification: .layoutChanged)
    }

    func controlTextDidChange(_ notification: Notification) {
        guard let field = nameField,
              notification.object as? NSTextField === field else { return }
        saveSpeakerName(field)
    }

    private func saveSpeakerName(_ field: NSTextField) {
        guard let id = editingSpeakerID, model?.document?.id == editingDocumentID else { return }
        let name = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if !name.isEmpty { model?.rename(id, name) }
    }

    func controlTextDidEndEditing(_ notification: Notification) {
        guard !startingNameEdit, let field = nameField,
              notification.object as? NSTextField === field else { return }
        finishRenaming()
    }

    private func finishRenaming() {
        guard let field = nameField else { return }
        saveSpeakerName(field)
        field.delegate = nil
        nameField = nil
        editingSpeakerID = nil
        editingDocumentID = nil
        if field.currentEditor() != nil { window?.endEditing(for: field) }
        field.removeFromSuperview()
        setAccessibilityChildren([])
        needsDisplay = true
        NSAccessibility.post(element: self, notification: .layoutChanged)
    }

    override func keyDown(with event: NSEvent) {
        guard let model else { return }
        let key = (event.charactersIgnoringModifiers ?? "").lowercased()
        if event.modifierFlags.contains(.command), key == "z" {
            if event.modifierFlags.contains(.shift) { model.redo() } else { model.undo() }; return
        }
        if event.modifierFlags.intersection([.command, .control, .option]).isEmpty {
            if key == " " { model.togglePlayback(); return }
            if let index = Int(key), index > 0, let speakers = model.document?.speakers, index <= speakers.count { model.assign([speakers[index - 1].id]); return }
            if key == "0" { model.assign([]); return }
            if key == "s" { model.split(); return }
            if key == "c" { model.confirm(); return }
            if event.keyCode == 123 { model.seek(model.playhead - 1); return }
            if event.keyCode == 124 { model.seek(model.playhead + 1); return }
        }
        super.keyDown(with: event)
    }
}
