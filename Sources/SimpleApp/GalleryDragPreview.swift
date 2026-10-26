import SwiftUI
import AppKit

/// AppKit owns the mouse sequence, so dragging a thumbnail never competes with a SwiftUI Button.
struct GalleryDragPreview: NSViewRepresentable {
    let projectID: UUID
    let imageID: UUID?
    let imageURL: URL?
    let isSelected: Bool
    let accessibilityLabel: String
    let onSelect: () -> Void
    let canDrop: (GalleryDragPayload) -> Bool
    let onDrop: (GalleryDragPayload, UUID?, Bool) -> Bool

    func makeNSView(context: Context) -> GalleryDragImageView {
        let view = GalleryDragImageView()
        updateNSView(view, context: context)
        return view
    }

    func updateNSView(_ view: GalleryDragImageView, context: Context) {
        view.projectID = projectID
        view.imageID = imageID
        view.updateImage(url: imageURL)
        view.isSelectedImage = isSelected
        view.onSelect = onSelect
        view.canDrop = canDrop
        view.onDrop = onDrop
        view.setAccessibilityLabel(accessibilityLabel)
        view.setAccessibilityIdentifier(imageID.map { "gallery-image-\($0.uuidString)" } ?? "gallery-drop-end")
        view.setAccessibilityRole(imageID == nil ? .group : .button)
        view.setAccessibilityHelp(imageID == nil ? "将图片拖到这里排到图库末尾" : "点击预览；拖到其他缩略图左侧或右侧调整顺序")
        view.needsDisplay = true
    }
}

final class GalleryDragImageView: NSView {
    var projectID = UUID()
    var imageID: UUID?
    var isSelectedImage = false
    var onSelect: () -> Void = {}
    var canDrop: (GalleryDragPayload) -> Bool = { _ in false }
    var onDrop: (GalleryDragPayload, UUID?, Bool) -> Bool = { _, _, _ in false }
    private var imageURL: URL?
    private var image: NSImage?
    private var mouseDownPoint: NSPoint?
    private var didBeginDrag = false
    private var isDragging = false
    private var insertionAfter: Bool?
    private var eventMonitor: Any?
    private var inactiveObserver: NSObjectProtocol?
    private weak var trackingWindow: NSWindow?
    private weak var dropTarget: GalleryDragImageView?
    private var dragPayload: GalleryDragPayload?

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { imageID != nil }

    init() {
        super.init(frame: .zero)
        setAccessibilityElement(true)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func updateImage(url: URL?) {
        guard imageURL != url else { return }
        imageURL = url
        image = url.flatMap(NSImage.init(contentsOf:))
    }

    override func draw(_ dirtyRect: NSRect) {
        let rounded = NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1), xRadius: 6, yRadius: 6)
        NSColor.controlBackgroundColor.setFill()
        rounded.fill()
        NSGraphicsContext.saveGraphicsState()
        rounded.addClip()
        if let image, image.size.width > 0, image.size.height > 0 {
            let scale = min(bounds.width / image.size.width, bounds.height / image.size.height)
            let size = NSSize(width: image.size.width * scale, height: image.size.height * scale)
            let rect = NSRect(x: (bounds.width - size.width) / 2, y: (bounds.height - size.height) / 2, width: size.width, height: size.height)
            image.draw(in: rect, from: .zero, operation: .sourceOver, fraction: isDragging ? 0.45 : 1, respectFlipped: true, hints: nil)
        } else if imageID == nil {
            let paragraph = NSMutableParagraphStyle()
            paragraph.alignment = .center
            let text = NSAttributedString(string: "拖到这里\n排到末尾", attributes: [.font: NSFont.systemFont(ofSize: 12), .foregroundColor: NSColor.secondaryLabelColor, .paragraphStyle: paragraph])
            let size = text.size()
            text.draw(in: NSRect(x: 4, y: (bounds.height - size.height) / 2, width: bounds.width - 8, height: size.height))
        }
        NSGraphicsContext.restoreGraphicsState()
        (isSelectedImage ? NSColor.controlAccentColor : NSColor.separatorColor).setStroke()
        rounded.lineWidth = isSelectedImage ? 2 : 1
        rounded.stroke()
        if let insertionAfter {
            NSColor.controlAccentColor.withAlphaComponent(0.12).setFill()
            rounded.fill()
            NSColor.controlAccentColor.setStroke()
            let marker = NSBezierPath()
            let x = imageID == nil ? 3 : (insertionAfter ? bounds.maxX - 3 : 3)
            marker.move(to: NSPoint(x: x, y: 4))
            marker.line(to: NSPoint(x: x, y: bounds.height - 4))
            marker.lineWidth = 4
            marker.lineCapStyle = .round
            marker.stroke()
        }
    }

    override func mouseDown(with event: NSEvent) {
        cancelTracking()
        guard let imageID, let window else { return }
        window.makeFirstResponder(self)
        mouseDownPoint = event.locationInWindow
        trackingWindow = window
        dragPayload = GalleryDragPayload(projectID: projectID, imageID: imageID)
        didBeginDrag = false
        // No NSDraggingSession is started. Keep the complete gesture inside this app,
        // including mouse-up events whose hit-tested view is no longer the source.
        eventMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDragged, .leftMouseUp, .leftMouseDown, .keyDown]) { [weak self] event in
            guard let self, self.mouseDownPoint != nil else { return event }
            if event.type == .keyDown {
                if event.keyCode == 53 { self.cancelTracking(); return nil }
                return event
            }
            if event.type == .leftMouseDown {
                self.cancelTracking()
                return event
            }
            guard event.window === self.trackingWindow else {
                if event.type == .leftMouseUp { self.cancelTracking() }
                return event
            }
            if event.type == .leftMouseDragged { self.mouseDragged(with: event) }
            else if event.type == .leftMouseUp { self.mouseUp(with: event) }
            return nil
        }
        inactiveObserver = NotificationCenter.default.addObserver(forName: NSApplication.didResignActiveNotification, object: nil, queue: .main) { [weak self] _ in
            self?.cancelTracking()
        }
    }

    override func mouseDragged(with event: NSEvent) {
        guard let start = mouseDownPoint, dragPayload != nil else { return }
        if !didBeginDrag {
            guard hypot(event.locationInWindow.x - start.x, event.locationInWindow.y - start.y) >= 4 else { return }
            didBeginDrag = true
            isDragging = true
            needsDisplay = true
        }
        updateDropTarget(at: event.locationInWindow)
        if event.type == .leftMouseDragged { _ = autoscroll(with: event) }
    }

    override func mouseUp(with event: NSEvent) {
        guard mouseDownPoint != nil else { return }
        if didBeginDrag {
            updateDropTarget(at: event.locationInWindow)
            let target = dropTarget
            let payload = dragPayload
            let after = target?.insertionAfter ?? false
            // Reset before persisting: SwiftUI may replace views as soon as order changes.
            cancelTracking()
            if let target, let payload { _ = target.onDrop(payload, target.imageID, after) }
        } else {
            let shouldSelect = imageID != nil && bounds.contains(convert(event.locationInWindow, from: nil))
            cancelTracking()
            if shouldSelect { onSelect() }
        }
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { cancelTracking() }
        else if imageID != nil, event.keyCode == 49 || event.keyCode == 36 { onSelect() }
        else { super.keyDown(with: event) }
    }

    override func accessibilityPerformPress() -> Bool {
        guard imageID != nil else { return false }
        onSelect()
        return true
    }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        if newWindow !== window { cancelTracking() }
        super.viewWillMove(toWindow: newWindow)
    }

    private func updateDropTarget(at point: NSPoint) {
        dropTarget?.clearInsertion()
        dropTarget = nil
        guard let window = trackingWindow, let content = window.contentView, let payload = dragPayload,
              content.bounds.contains(content.convert(point, from: nil)) else { return }
        guard let target = Self.target(in: content, at: point, payload: payload) else { return }
        target.insertionAfter = target.imageID == nil || target.convert(point, from: nil).x >= target.bounds.midX
        target.needsDisplay = true
        dropTarget = target
    }

    private static func target(in view: NSView, at point: NSPoint, payload: GalleryDragPayload) -> GalleryDragImageView? {
        guard !view.isHiddenOrHasHiddenAncestor else { return nil }
        if let thumbnail = view as? GalleryDragImageView {
            let local = thumbnail.convert(point, from: nil)
            if thumbnail.projectID == payload.projectID, thumbnail.imageID != payload.imageID,
               thumbnail.visibleRect.contains(local), thumbnail.bounds.contains(local), thumbnail.canDrop(payload) {
                return thumbnail
            }
        }
        // Traverse in reverse drawing order so the visible uppermost target wins.
        for child in view.subviews.reversed() {
            if let target = target(in: child, at: point, payload: payload) { return target }
        }
        return nil
    }

    private func cancelTracking() {
        if let eventMonitor { NSEvent.removeMonitor(eventMonitor) }
        eventMonitor = nil
        if let inactiveObserver { NotificationCenter.default.removeObserver(inactiveObserver) }
        inactiveObserver = nil
        dropTarget?.clearInsertion()
        dropTarget = nil
        mouseDownPoint = nil
        trackingWindow = nil
        dragPayload = nil
        didBeginDrag = false
        isDragging = false
        insertionAfter = nil
        needsDisplay = true
    }

    private func clearInsertion() {
        insertionAfter = nil
        needsDisplay = true
    }
}
