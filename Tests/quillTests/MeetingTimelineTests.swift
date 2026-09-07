import AppKit
import XCTest
@testable import quill

/// These views remain unattached to any window. Synthetic events are passed only
/// to the zoom calculation; nothing is posted to the application or desktop.
@MainActor
final class MeetingTimelineTests: XCTestCase {
    private func fixture() -> (MeetingEditorModel, MeetingTimelineScrollView, MeetingTimelineView) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let model = MeetingEditorModel(root: root, modelProvider: { .default })
        model.document = MeetingDocument(title: "Zoom fixture", audioFilename: "original.m4a", duration: 120,
                                         speakers: [.init(id: "speaker-1", name: "Speaker 1")])
        let scroll = MeetingTimelineScrollView(frame: NSRect(x: 0, y: 0, width: 1000, height: 300))
        scroll.hasHorizontalScroller = false
        scroll.hasVerticalScroller = false
        let timeline = MeetingTimelineView()
        timeline.model = model
        scroll.documentView = timeline
        scroll.layoutSubtreeIfNeeded()
        scroll.updateGeometry()
        return (model, scroll, timeline)
    }

    private func pointer(at time: Double, in timeline: MeetingTimelineView) throws -> NSEvent {
        let point = timeline.convert(NSPoint(x: timeline.x(for: time), y: 60), to: nil)
        return try XCTUnwrap(NSEvent.mouseEvent(with: .mouseMoved, location: point,
                                              modifierFlags: [], timestamp: 0, windowNumber: 0,
                                              context: nil, eventNumber: 0, clickCount: 0, pressure: 0))
    }

    func testZoomKeepsTimeBeneathPointerAtSameViewportPosition() throws {
        let (model, scroll, timeline) = fixture()
        let anchor = 48.0
        let originalOffset = timeline.x(for: anchor) - scroll.contentView.bounds.minX
        let event = try pointer(at: anchor, in: timeline)

        scroll.zoomTimeline(with: event, factor: 2)

        XCTAssertEqual(model.zoom, 2)
        XCTAssertGreaterThan(scroll.contentView.bounds.minX, 0)
        XCTAssertEqual(timeline.x(for: anchor) - scroll.contentView.bounds.minX, originalOffset, accuracy: 0.5,
                       "Zoom must preserve the timestamp under the pointer, not jump to the playhead or selected segment.")
        XCTAssertEqual(timeline.lastZoom, model.zoom, "The next SwiftUI update must not replace the pointer anchor.")
    }

    func testZoomPreservesPointerAnchorWhenAlreadyPanned() throws {
        let (model, scroll, timeline) = fixture()
        model.zoom = 4
        timeline.lastZoom = model.zoom
        scroll.updateGeometry()
        scroll.contentView.scroll(to: NSPoint(x: 900, y: 0))
        let anchor = 52.0
        let originalOffset = timeline.x(for: anchor) - scroll.contentView.bounds.minX
        XCTAssertGreaterThan(originalOffset, 150)
        XCTAssertLessThan(originalOffset, scroll.contentSize.width)
        let event = try pointer(at: anchor, in: timeline)

        scroll.zoomTimeline(with: event, factor: 1.5)

        XCTAssertEqual(model.zoom, 6)
        XCTAssertEqual(timeline.x(for: anchor) - scroll.contentView.bounds.minX, originalOffset, accuracy: 0.5)
    }

    func testZoomClampsToLimitsAndFitReturnsToBeginning() throws {
        let (model, scroll, timeline) = fixture()
        scroll.zoomTimeline(with: try pointer(at: 50, in: timeline), factor: 100)
        XCTAssertEqual(model.zoom, 32)
        XCTAssertGreaterThanOrEqual(scroll.contentView.bounds.minX, 0)
        XCTAssertLessThanOrEqual(scroll.contentView.bounds.maxX, timeline.bounds.width + 0.5)

        scroll.zoomTimeline(with: try pointer(at: 50, in: timeline), factor: 0.0001)
        XCTAssertEqual(model.zoom, 1)
        XCTAssertEqual(scroll.contentView.bounds.minX, 0, accuracy: 0.5)
        XCTAssertEqual(timeline.bounds.width, scroll.contentSize.width, accuracy: 0.5)
    }

    func testInvalidZoomFactorsLeaveViewportUnchanged() throws {
        let (model, scroll, timeline) = fixture()
        let event = try pointer(at: 50, in: timeline)
        let originalBounds = scroll.contentView.bounds
        for factor in [Double.nan, .infinity, 0, -1] {
            scroll.zoomTimeline(with: event, factor: factor)
            XCTAssertEqual(model.zoom, 1)
            XCTAssertEqual(scroll.contentView.bounds, originalBounds)
        }
    }
    private func doubleClickFirstLabel(in timeline: MeetingTimelineView) throws {
        let point = timeline.convert(NSPoint(x: 25, y: 124), to: nil)
        let event = try XCTUnwrap(NSEvent.mouseEvent(with: .leftMouseDown, location: point,
                                                   modifierFlags: [], timestamp: 0, windowNumber: 0,
                                                   context: nil, eventNumber: 0, clickCount: 2, pressure: 0))
        timeline.mouseDown(with: event)
    }

    func testLaneDoubleClickCreatesAnAccessibleInlineNameField() throws {
        let views = fixture()
        defer { withExtendedLifetime(views) {} }
        let timeline = views.2
        try doubleClickFirstLabel(in: timeline)
        let field = try XCTUnwrap(timeline.subviews.compactMap { $0 as? NSTextField }.first)
        XCTAssertEqual(field.stringValue, "Speaker 1")
        XCTAssertTrue(field.isEditable)
        XCTAssertFalse(field.isHidden)
        XCTAssertTrue(timeline.accessibilityChildren()?.contains { ($0 as? NSTextField) === field } == true)
    }

    func testDelayedEndEditingFromPreviousFieldDoesNotDismissCurrentNameField() throws {
        let views = fixture()
        defer { withExtendedLifetime(views) {} }
        let timeline = views.2
        try doubleClickFirstLabel(in: timeline)
        let previous = try XCTUnwrap(timeline.subviews.compactMap { $0 as? NSTextField }.first)
        try doubleClickFirstLabel(in: timeline)
        let current = try XCTUnwrap(timeline.subviews.compactMap { $0 as? NSTextField }.first)
        XCTAssertFalse(previous === current)

        timeline.controlTextDidEndEditing(Notification(name: NSControl.textDidEndEditingNotification, object: previous))
        XCTAssertTrue(current.superview === timeline)

        timeline.controlTextDidEndEditing(Notification(name: NSControl.textDidEndEditingNotification, object: current))
        XCTAssertNil(current.superview)
        XCTAssertTrue(timeline.subviews.compactMap { $0 as? NSTextField }.isEmpty)
    }

}
