import AppKit

/// Corner rounding for the exported screenshot. Top/bottom flags let a browser crop (top trimmed off) round only its bottom corners.
struct Corners {
    var radius: CGFloat = 0
    var top = true
    var bottom = true

    func scaled(_ k: CGFloat) -> Corners { Corners(radius: radius * k, top: top, bottom: bottom) }

    /// `flipped` = origin at top-left (view coordinates); false = Core Graphics image coordinates.
    func path(_ r: CGRect, flipped: Bool) -> CGPath {
        let topY = flipped ? r.minY : r.maxY, botY = flipped ? r.maxY : r.minY
        let rt = top ? radius : 0, rb = bottom ? radius : 0
        let p = CGMutablePath()
        p.move(to: CGPoint(x: r.midX, y: topY))
        p.addArc(tangent1End: CGPoint(x: r.maxX, y: topY), tangent2End: CGPoint(x: r.maxX, y: botY), radius: rt)
        p.addArc(tangent1End: CGPoint(x: r.maxX, y: botY), tangent2End: CGPoint(x: r.minX, y: botY), radius: rb)
        p.addArc(tangent1End: CGPoint(x: r.minX, y: botY), tangent2End: CGPoint(x: r.minX, y: topY), radius: rb)
        p.addArc(tangent1End: CGPoint(x: r.minX, y: topY), tangent2End: CGPoint(x: r.midX, y: topY), radius: rt)
        p.closeSubpath()
        return p
    }
}

private final class OverlayWindow: NSWindow {
    override var canBecomeKey: Bool { true }
}

/// Everything the overlay needs to know about what is being captured. Rects are global points (origin top-left).
struct CaptureContext {
    enum Mode { case window, selection }
    var mode: Mode = .selection
    var contentRect: CGRect?          // area to preselect (nil = drag a new one)
    var windowRect: CGRect?           // full window; enables the trim fields
    var margins = Margins()           // initial trim (window mode)
    var radius: Double = 0
    var rememberTitle = ""
    var remember = true
    var quickTitle: String?           // "Auto" or "Reset"
    var quickIsAuto = false
    var quick: (() -> Margins?)?      // new trim (and radius) when the quick button is pressed
    var expected: CGSize?
}

/// What the user changed in the overlay, reported when they press Done.
struct Outcome {
    var radius: CGFloat
    var trim: Margins?                // current trim, clamped to >= 0 (window mode only)
    var trimEdited: Bool
    var radiusEdited: Bool
    var usedAuto: Bool
    var usedReset: Bool
    var remember: Bool
}

struct CaptureResult {
    var globalRect: CGRect            // final selection, global points
    var outcome: Outcome
}

/// Freezes the screen, lets the user pick an area (or uses a preselected one), and collects vector annotations.
final class Overlay {
    private static var current: Overlay?
    static var isActive: Bool { current != nil }

    private let window: OverlayWindow
    private let view: OverlayView
    private let cg: CGImage
    private let scale: CGFloat
    private let frameOrigin: CGPoint
    private var onSaved: (() -> Void)?
    private var persist: ((CaptureResult) -> Void)?

    static func begin(_ ctx: CaptureContext = CaptureContext(), persist: ((CaptureResult) -> Void)? = nil, onSaved: (() -> Void)? = nil) {
        guard current == nil else { return }
        let primaryH = NSScreen.screens[0].frame.height
        func topLeft(_ s: NSScreen) -> CGRect {
            CGRect(x: s.frame.minX, y: primaryH - s.frame.maxY, width: s.frame.width, height: s.frame.height)
        }
        func mid(_ r: CGRect) -> CGPoint { CGPoint(x: r.midX, y: r.midY) }
        let mouse = CGPoint(x: NSEvent.mouseLocation.x, y: primaryH - NSEvent.mouseLocation.y)
        // A remembered area on a monitor that is no longer connected is ignored.
        let probe = [ctx.windowRect, ctx.contentRect].compactMap { $0 }.map(mid).first { p in NSScreen.screens.contains { topLeft($0).contains(p) } } ?? mouse
        guard let screen = NSScreen.screens.first(where: { topLeft($0).contains(probe) }) ?? NSScreen.main else { return }
        let frame = topLeft(screen)

        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("fc-\(UUID().uuidString).png")
        defer { try? FileManager.default.removeItem(at: tmp) }
        PreviewHUD.shared.hideForCapture()   // keep our own thumbnail out of the screenshot
        guard Capture.screen(frame: frame, to: tmp),
              let data = try? Data(contentsOf: tmp),
              let cg = NSBitmapImageRep(data: data)?.cgImage else { PreviewHUD.shared.refresh(); NSSound.beep(); return }

        var local = ctx
        let bounds = CGRect(origin: .zero, size: frame.size)
        local.windowRect = ctx.windowRect?.offsetBy(dx: -frame.minX, dy: -frame.minY)
        if let c = ctx.contentRect?.offsetBy(dx: -frame.minX, dy: -frame.minY).intersection(bounds), !c.isNull, c.width > 10, c.height > 10 {
            local.contentRect = c
        } else { local.contentRect = nil }

        let o = Overlay(screen: screen, frameOrigin: frame.origin, cg: cg, scale: CGFloat(cg.width) / frame.width, ctx: local)
        o.onSaved = onSaved; o.persist = persist
        current = o
    }

    private init(screen: NSScreen, frameOrigin: CGPoint, cg: CGImage, scale: CGFloat, ctx: CaptureContext) {
        self.cg = cg; self.scale = scale; self.frameOrigin = frameOrigin
        view = OverlayView(frame: CGRect(origin: .zero, size: screen.frame.size),
                           image: NSImage(cgImage: cg, size: screen.frame.size), ctx: ctx, topInset: screen.safeAreaInsets.top)
        window = OverlayWindow(contentRect: screen.frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.level = .screenSaver
        window.isOpaque = true
        window.hasShadow = false
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        window.contentView = view
        view.onDone = { [weak self] sel, items, outcome in self?.finish(sel, items, outcome) }
        view.onCancel = { [weak self] in self?.close() }
        window.setFrame(screen.frame, display: true)
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        window.makeFirstResponder(view)
    }

    private func finish(_ sel: CGRect, _ items: [Annotation], _ outcome: Outcome) {
        let px = CGRect(x: sel.minX * scale, y: sel.minY * scale, width: sel.width * scale, height: sel.height * scale).integral
        let corners = Corners(radius: outcome.radius)
        if let crop = cg.cropping(to: px).map({ rounded($0, corners.scaled(scale)) }),
           let png = NSBitmapImageRep(cgImage: crop).representation(using: .png, properties: [:]) {
            let id = UUID().uuidString
            try? png.write(to: Store.shared.imageURL(for: id))
            // Re-anchor annotations to the crop's top-left so FigJam can place them relative to the screenshot.
            let local = items.map { a -> Annotation in
                var b = a
                b.x -= sel.minX; b.y -= sel.minY; b.x2 -= sel.minX; b.y2 -= sel.minY
                return b
            }
            Store.shared.add(id: id, width: sel.width, height: sel.height, annotations: local)
            persist?(CaptureResult(globalRect: sel.offsetBy(dx: frameOrigin.x, dy: frameOrigin.y), outcome: outcome))
            onSaved?()
        }
        close()
    }

    /// Clips the corners to transparent so the exported PNG (and FigJam) shows a rounded screenshot.
    private func rounded(_ img: CGImage, _ c: Corners) -> CGImage {
        guard c.radius > 0,
              let ctx = CGContext(data: nil, width: img.width, height: img.height, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return img }
        let rect = CGRect(x: 0, y: 0, width: img.width, height: img.height)
        ctx.addPath(c.path(rect, flipped: false))
        ctx.clip()
        ctx.draw(img, in: rect)
        return ctx.makeImage() ?? img
    }

    private func close() {
        window.orderOut(nil)
        Overlay.current = nil
        PreviewHUD.shared.refresh()
    }
}

// MARK: - View

private let arrowColor = NSColor(calibratedRed: 0.93, green: 0.23, blue: 0.23, alpha: 1)
private let stickyFont: CGFloat = 20   // approximate; FigJam's default sticky text size

final class OverlayView: NSView, NSTextFieldDelegate {
    enum Phase { case selecting, annotating }
    enum Tool { case select, arrow, rect, oval, text }
    enum Handle: CaseIterable { case tl, t, tr, r, br, b, bl, l }
    enum Drag {
        case none
        case select(start: CGPoint)
        case move(id: UUID, last: CGPoint)
        case endpoint(id: UUID, end: Int)
        case newArrow(id: UUID)
        case newSticky(id: UUID, grab: CGPoint)
        case newShape(id: UUID, origin: CGPoint)
        case shapeCorner(id: UUID, anchor: CGPoint)
        case resize(handle: Handle, original: CGRect)
        case moveToolbar(startMouse: CGPoint, startOffset: CGSize)

        var isIdle: Bool { if case .none = self { return true } else { return false } }
    }
    enum Button: CaseIterable {
        case sticky, arrow, rect, oval, text, select, more, done, cancel
        var name: String {
            switch self {
            case .sticky: return "Sticky"; case .arrow: return "Arrow"; case .rect: return "Rect"; case .oval: return "Oval"
            case .text: return "Text"; case .select: return "Select"; case .more: return "•••"; case .done: return "Done"; case .cancel: return "Cancel"
            }
        }
        var key: String? {
            switch self {
            case .sticky: return "S"; case .arrow: return "A"; case .rect: return "R"; case .oval: return "O"
            case .text: return "T"; case .select: return "V"; case .more: return nil; case .done: return "⏎"; case .cancel: return "⎋"
            }
        }
    }

    var onDone: ((CGRect, [Annotation], Outcome) -> Void)?
    var onCancel: (() -> Void)?

    private let image: NSImage
    private var corners: Corners
    private let expected: CGSize?
    private let ctx: CaptureContext
    private let windowView: CGRect?
    private let initialTrim: Margins
    private let initialRadius: CGFloat
    private var usedAuto = false, usedReset = false, rememberOn: Bool
    private let inspector: InspectorView
    private var phase: Phase
    private var selection: CGRect?
    private var items: [Annotation] = []
    private var tool: Tool = .select
    private var drag: Drag = .none
    private var selected: UUID?
    private var dragStart: CGPoint = .zero
    private var editor: NSTextField?
    private var editingID: UUID?

    /// Thumbnails of earlier steps in this flow (last 8), numbered by their position in the flow.
    private let previous: [(num: Int, image: NSImage)]
    private let totalSteps: Int
    /// Height of the notch / camera housing on MacBooks; controls start below it.
    private let topInset: CGFloat
    private var toolbarOffset: CGSize = Prefs.toolbarOffset
    private var topMargin: CGFloat { max(18, topInset + 8) }
    private let k: CGFloat = Prefs.uiScale          // overlay control size (compact by default)
    private var thumbH: CGFloat { 84 * k }

    private var sw: CGFloat { CGFloat(FigJamMetrics.stickyWidth) }
    private var sh: CGFloat { CGFloat(FigJamMetrics.stickyHeight) }

    init(frame: NSRect, image: NSImage, ctx: CaptureContext, topInset: CGFloat) {
        self.image = image
        self.topInset = topInset
        self.ctx = ctx
        self.expected = ctx.expected
        self.corners = Corners(radius: CGFloat(ctx.radius))
        self.initialRadius = CGFloat(ctx.radius)
        self.windowView = ctx.windowRect
        self.initialTrim = ctx.margins
        self.rememberOn = ctx.remember
        self.selection = ctx.contentRect
        self.phase = ctx.contentRect == nil ? .selecting : .annotating
        self.inspector = InspectorView(scale: Prefs.uiScale, showTrim: ctx.windowRect != nil, quickTitle: ctx.quickTitle,
                                       rememberTitle: ctx.rememberTitle, rememberOn: ctx.remember)
        let recs = Store.shared.openFlowRecords()
        totalSteps = recs.count
        previous = recs.enumerated().suffix(8).compactMap { i, r in
            NSImage(contentsOf: Store.shared.imageURL(for: r.id)).map { (i + 1, $0) }
        }
        super.init(frame: frame)

        inspector.frame.origin = CGPoint(x: 18, y: topMargin)
        inspector.isHidden = phase == .selecting
        inspector.onChange = { [weak self] in self?.applyInspector() }
        inspector.onFocusBack = { [weak self] in self.map { $0.window?.makeFirstResponder($0) } }
        inspector.onQuick = { [weak self] in self?.quickAction() }
        inspector.onRemember = { [weak self] on in
            self?.rememberOn = on
            if self?.ctx.mode == .selection { Prefs.rememberSelection = on }
        }
        addSubview(inspector)
        syncInspector()
    }
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override func resetCursorRects() { if phase == .selecting { addCursorRect(bounds, cursor: .crosshair) } }

    // MARK: Drawing

    override func draw(_ dirty: NSRect) {
        image.draw(in: bounds)
        let ctx = NSGraphicsContext.current!.cgContext
        ctx.setFillColor(NSColor.black.withAlphaComponent(0.45).cgColor)
        ctx.addRect(bounds)
        if let s = selection { ctx.addPath(corners.path(s, flipped: true)) }
        ctx.fillPath(using: .evenOdd)
        if let s = selection {
            ctx.setStrokeColor(NSColor.white.cgColor); ctx.setLineWidth(1)
            ctx.addPath(corners.path(s, flipped: true)); ctx.strokePath()
        }
        if phase == .annotating, let sel = selection { drawHandles(sel) }
        drawSizeLabel()
        for a in items {
            switch a.kind {
            case .sticky: drawSticky(a)
            case .arrow: drawArrow(a)
            case .rect, .oval: drawShape(a)
            case .text: drawText(a)
            }
        }
        if let a = selectedItem, drag.isIdle { drawStyleBar(for: a) }
        if phase == .selecting { hint("Drag to select an area  ·  Esc to cancel") } else { drawToolbar() }
        drawFilmstrip()
    }

    // MARK: Selection handles

    private func handleRects(_ s: CGRect) -> [(Handle, CGRect)] {
        let pts: [(Handle, CGPoint)] = [
            (.tl, CGPoint(x: s.minX, y: s.minY)), (.t, CGPoint(x: s.midX, y: s.minY)), (.tr, CGPoint(x: s.maxX, y: s.minY)),
            (.r, CGPoint(x: s.maxX, y: s.midY)), (.br, CGPoint(x: s.maxX, y: s.maxY)), (.b, CGPoint(x: s.midX, y: s.maxY)),
            (.bl, CGPoint(x: s.minX, y: s.maxY)), (.l, CGPoint(x: s.minX, y: s.midY)),
        ]
        return pts.map { ($0.0, CGRect(x: $0.1.x - 5, y: $0.1.y - 5, width: 10, height: 10)) }
    }

    private func drawHandles(_ s: CGRect) {
        for (_, r) in handleRects(s) {
            NSColor.white.setFill(); NSBezierPath(roundedRect: r, xRadius: 2, yRadius: 2).fill()
            NSColor.black.withAlphaComponent(0.5).setStroke(); NSBezierPath(roundedRect: r, xRadius: 2, yRadius: 2).stroke()
        }
    }

    private func handle(at p: CGPoint) -> Handle? {
        guard phase == .annotating, let s = selection else { return nil }
        return handleRects(s).first { $0.1.insetBy(dx: -5, dy: -5).contains(p) }?.0
    }

    private func resized(_ o: CGRect, _ h: Handle, to p: CGPoint) -> CGRect {
        let minSize: CGFloat = 24
        var r = o
        if [.tl, .l, .bl].contains(h) { let x = min(max(p.x, 0), o.maxX - minSize); r.origin.x = x; r.size.width = o.maxX - x }
        if [.tr, .r, .br].contains(h) { r.size.width = max(minSize, min(p.x, bounds.maxX) - o.minX) }
        if [.tl, .t, .tr].contains(h) { let y = min(max(p.y, 0), o.maxY - minSize); r.origin.y = y; r.size.height = o.maxY - y }
        if [.bl, .b, .br].contains(h) { r.size.height = max(minSize, min(p.y, bounds.maxY) - o.minY) }
        return r
    }

    // MARK: Trim & corners panel

    private func trim(for sel: CGRect) -> Margins? {
        guard let w = windowView else { return nil }
        return Margins(top: sel.minY - w.minY, right: w.maxX - sel.maxX, bottom: w.maxY - sel.maxY, left: sel.minX - w.minX)
    }

    private func syncInspector() {
        guard let sel = selection else { return }
        inspector.show(trim: trim(for: sel), radius: corners.radius)
    }

    /// Typed values move the selection and corners, so what you see is what will be saved.
    private func applyInspector() {
        let before = (selection, corners.radius)
        defer {
            // A manual change after Auto / Reset is what the user wants remembered, not the Auto / Reset result.
            func moved(_ a: CGRect?, _ b: CGRect?) -> Bool {
                guard let a, let b else { return (a == nil) != (b == nil) }
                return abs(a.minX - b.minX) > 0.75 || abs(a.minY - b.minY) > 0.75 || abs(a.width - b.width) > 0.75 || abs(a.height - b.height) > 0.75
            }
            if moved(selection, before.0) || abs(corners.radius - before.1) > 0.75 { usedAuto = false; usedReset = false }
        }
        let v = inspector.values()
        if let w = windowView, let t = v.trim {
            let r = CGRect(x: w.minX + t.left, y: w.minY + t.top, width: w.width - t.left - t.right, height: w.height - t.top - t.bottom)
            if r.width > 20, r.height > 20 { selection = r }
        }
        corners.radius = CGFloat(max(0, v.radius))
        syncInspector(); needsDisplay = true
    }

    private func quickAction() {
        guard let m = ctx.quick?() else { NSSound.beep(); return }
        if let w = windowView {
            selection = CGRect(x: w.minX + m.left, y: w.minY + m.top, width: w.width - m.left - m.right, height: w.height - m.top - m.bottom)
        }
        if ctx.quickIsAuto { usedAuto = true; usedReset = false; if m.radius > 0 { corners.radius = CGFloat(m.radius) } }
        else { usedReset = true; usedAuto = false; corners.radius = CGFloat(m.radius) }
        syncInspector(); needsDisplay = true
    }

    // MARK: Filmstrip

    private func thumbSize(_ img: NSImage) -> CGSize {
        let w = min(160 * k, thumbH * img.size.width / max(img.size.height, 1))
        return CGSize(width: w, height: thumbH)
    }

    /// Bar along the bottom listing earlier steps plus a marker for the step being captured now.
    private func filmstripRect() -> CGRect? {
        guard !previous.isEmpty else { return nil }
        let widths = previous.map { thumbSize($0.image).width } + [90 * k]
        let total = widths.reduce(0, +) + 10 * k * CGFloat(widths.count + 1)
        return CGRect(x: bounds.midX - total / 2, y: bounds.maxY - thumbH - 44 * k, width: total, height: thumbH + 28 * k)
    }

    private func drawFilmstrip() {
        guard let bar = filmstripRect() else { return }
        NSColor.black.withAlphaComponent(0.8).setFill(); NSBezierPath(roundedRect: bar, xRadius: 12, yRadius: 12).fill()
        let label: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 11 * max(k, 0.85), weight: .semibold), .foregroundColor: NSColor.white]
        var x = bar.minX + 10 * k
        for (num, img) in previous {
            let sz = thumbSize(img), r = CGRect(x: x, y: bar.minY + 14 * k, width: sz.width, height: sz.height)
            NSGraphicsContext.saveGraphicsState()
            NSBezierPath(roundedRect: r, xRadius: 4, yRadius: 4).addClip()
            img.draw(in: r)
            NSGraphicsContext.restoreGraphicsState()
            NSColor.white.withAlphaComponent(0.6).setStroke(); NSBezierPath(roundedRect: r, xRadius: 4, yRadius: 4).stroke()
            ("\(num)" as NSString).draw(at: CGPoint(x: r.minX + 2, y: bar.minY + 1), withAttributes: label)
            x += sz.width + 10 * k
        }
        let now = CGRect(x: x, y: bar.minY + 14 * k, width: 90 * k, height: thumbH)
        NSColor.systemBlue.setStroke()
        let dash = NSBezierPath(roundedRect: now, xRadius: 4, yRadius: 4); dash.setLineDash([5, 4], count: 2, phase: 0); dash.lineWidth = 1.5; dash.stroke()
        let t = "Step \(totalSteps + 1)" as NSString, size = t.size(withAttributes: label)
        t.draw(at: CGPoint(x: now.midX - size.width / 2, y: now.midY - size.height / 2), withAttributes: label)
    }

    /// Exact size of the area that will be exported; orange when it differs from the preset last applied to this window.
    private func drawSizeLabel() {
        guard let sel = selection, sel.width > 0 else { return }
        let w = Int(sel.width.rounded()), h = Int(sel.height.rounded())
        var text = "\(w) × \(h)"
        var color = NSColor.black.withAlphaComponent(0.8)
        if let e = expected, abs(sel.width - e.width) > 1 || abs(sel.height - e.height) > 1 {
            text += "   (preset \(Int(e.width)) × \(Int(e.height)))"
            color = NSColor.systemOrange.withAlphaComponent(0.95)
        }
        let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.monospacedDigitSystemFont(ofSize: 12 * max(k, 0.85), weight: .semibold), .foregroundColor: NSColor.white]
        let size = (text as NSString).size(withAttributes: attrs)
        let r = CGRect(x: sel.minX, y: sel.minY >= 30 ? sel.minY - 26 * k - 4 : sel.minY + 6, width: size.width + 16, height: 22 * k)
        color.setFill(); NSBezierPath(roundedRect: r, xRadius: 6, yRadius: 6).fill()
        (text as NSString).draw(at: CGPoint(x: r.minX + 8, y: r.minY + (r.height - size.height) / 2), withAttributes: attrs)
    }

    private func drawSticky(_ a: Annotation) {
        let r = CGRect(x: a.x, y: a.y, width: sw, height: sh)
        NSGraphicsContext.saveGraphicsState()
        let shadow = NSShadow(); shadow.shadowColor = NSColor.black.withAlphaComponent(0.3)
        shadow.shadowBlurRadius = 8; shadow.shadowOffset = NSSize(width: 0, height: -3); shadow.set()
        (StickyColor(rawValue: a.color) ?? .yellow).nsColor.setFill(); NSBezierPath(roundedRect: r, xRadius: 4, yRadius: 4).fill()
        NSGraphicsContext.restoreGraphicsState()
        if a.id == selected {
            NSColor.systemBlue.setStroke()
            let p = NSBezierPath(roundedRect: r.insetBy(dx: -2, dy: -2), xRadius: 5, yRadius: 5); p.lineWidth = 2; p.stroke()
        }
        if a.id != editingID {
            StickyStyle.attributed(a, fontSize: stickyFont).draw(in: r.insetBy(dx: 10, dy: 10))
        }
    }

    // MARK: Geometry of shapes and text

    private func shapeRect(_ a: Annotation) -> CGRect {
        CGRect(x: min(a.x, a.x2), y: min(a.y, a.y2), width: abs(a.x2 - a.x), height: abs(a.y2 - a.y))
    }

    /// Rectangle or oval from `a` to `b`; with `square` it becomes a square or circle.
    private func shapeBounds(from a: CGPoint, to b: CGPoint, square: Bool) -> CGRect {
        var dx = b.x - a.x, dy = b.y - a.y
        if square { let m = max(abs(dx), abs(dy)); dx = dx < 0 ? -m : m; dy = dy < 0 ? -m : m }
        return CGRect(x: min(a.x, a.x + dx), y: min(a.y, a.y + dy), width: abs(dx), height: abs(dy))
    }

    private func setShape(_ i: Int, _ r: CGRect) { items[i].x = r.minX; items[i].y = r.minY; items[i].x2 = r.maxX; items[i].y2 = r.maxY }

    private func lineWidth(_ a: Annotation) -> CGFloat { (LineWeight(rawValue: a.weight) ?? .medium).points }
    private func strokeColor(_ a: Annotation) -> NSColor { (StrokeColor(rawValue: a.stroke) ?? .red).nsColor }
    private func dash(_ path: NSBezierPath, _ a: Annotation) {
        if a.dashed { let w = lineWidth(a); path.setLineDash([w * 3, w * 2], count: 2, phase: 0) }
    }

    private func textFont(_ a: Annotation) -> NSFont { .systemFont(ofSize: (TextSize(rawValue: a.size) ?? .medium).points) }

    /// Box of a text annotation: fixed wrap width, height from the laid-out text.
    private func textRect(_ a: Annotation) -> CGRect {
        let w = max(40, a.x2 - a.x)
        let str = NSAttributedString(string: a.text.isEmpty ? " " : a.text, attributes: [.font: textFont(a)])
        let h = str.boundingRect(with: CGSize(width: w, height: 10_000), options: [.usesLineFragmentOrigin]).height
        return CGRect(x: a.x, y: a.y, width: w, height: max(ceil(h) + 4, 28))
    }

    private func bounds(of a: Annotation) -> CGRect {
        switch a.kind {
        case .sticky: return CGRect(x: a.x, y: a.y, width: sw, height: sh)
        case .text: return textRect(a)
        case .rect, .oval: return shapeRect(a)
        case .arrow: return CGRect(x: min(a.x, a.x2), y: min(a.y, a.y2), width: abs(a.x2 - a.x), height: abs(a.y2 - a.y))
        }
    }

    private func drawShape(_ a: Annotation) {
        let r = shapeRect(a)
        strokeColor(a).setStroke()
        let path = a.kind == .oval ? NSBezierPath(ovalIn: r) : NSBezierPath(rect: r)
        path.lineWidth = lineWidth(a); dash(path, a); path.stroke()
        if a.id == selected {
            NSColor.systemBlue.setFill()
            for c in corners4(r) { NSBezierPath(ovalIn: CGRect(x: c.x - 5, y: c.y - 5, width: 10, height: 10)).fill() }
        }
    }

    private func drawText(_ a: Annotation) {
        let r = textRect(a)
        if a.id != editingID {
            NSAttributedString(string: a.text, attributes: [.font: textFont(a), .foregroundColor: strokeColor(a)])
                .draw(with: r, options: [.usesLineFragmentOrigin])
        }
        if a.id == selected {
            NSColor.systemBlue.setStroke()
            let b = NSBezierPath(rect: r.insetBy(dx: -3, dy: -3)); b.lineWidth = 1; b.setLineDash([4, 3], count: 2, phase: 0); b.stroke()
        }
    }

    private func drawArrow(_ a: Annotation) {
        let s = CGPoint(x: a.x, y: a.y), e = CGPoint(x: a.x2, y: a.y2), w = lineWidth(a)
        strokeColor(a).setStroke()
        let shaft = NSBezierPath(); shaft.lineWidth = w; shaft.lineCapStyle = .round
        shaft.move(to: s); shaft.line(to: e); dash(shaft, a); shaft.stroke()
        let head = NSBezierPath(); head.lineWidth = w; head.lineCapStyle = .round; head.lineJoinStyle = .round
        let ang = atan2(e.y - s.y, e.x - s.x), len = 10 + 2 * w
        for d in [CGFloat.pi * 0.8, -CGFloat.pi * 0.8] {
            head.move(to: e)
            head.line(to: CGPoint(x: e.x + len * cos(ang + d), y: e.y + len * sin(ang + d)))
        }
        head.stroke()
        if a.id == selected {
            NSColor.systemBlue.setFill()
            for p in [s, e] { NSBezierPath(ovalIn: CGRect(x: p.x - 5, y: p.y - 5, width: 10, height: 10)).fill() }
        }
    }

    private func corners4(_ r: CGRect) -> [CGPoint] {
        [CGPoint(x: r.minX, y: r.minY), CGPoint(x: r.maxX, y: r.minY), CGPoint(x: r.maxX, y: r.maxY), CGPoint(x: r.minX, y: r.maxY)]
    }

    /// Distance from `p` to the shape's outline (shapes are hollow, so only the outline is clickable).
    private func outlineDistance(_ p: CGPoint, _ a: Annotation) -> CGFloat {
        let r = shapeRect(a)
        if a.kind == .oval {
            let rx = max(r.width / 2, 1), ry = max(r.height / 2, 1)
            let n = hypot((p.x - r.midX) / rx, (p.y - r.midY) / ry)
            return abs(n - 1) * min(rx, ry)
        }
        let dx = max(r.minX - p.x, 0, p.x - r.maxX), dy = max(r.minY - p.y, 0, p.y - r.maxY)
        if dx > 0 || dy > 0 { return hypot(dx, dy) }
        return min(p.x - r.minX, r.maxX - p.x, p.y - r.minY, r.maxY - p.y)
    }

    // MARK: Style bar (colour, list, line, size), shown above the selected item

    private enum StyleAction: Equatable {
        case stickyColor(StickyColor), list(String), stroke(StrokeColor), weight(LineWeight), dashed, size(TextSize)
    }

    private var selectedItem: Annotation? { index(selected).map { items[$0] } }

    private func styleBarItems(for a: Annotation) -> [(StyleAction, CGRect)] {
        let h: CGFloat = 22 * k, pad: CGFloat = 6 * k
        let b = bounds(of: a)
        var y = b.minY - h - pad * 2 - 6
        if y < 8 { y = b.maxY + 6 }
        var x = b.minX + pad
        var out: [(StyleAction, CGRect)] = []
        func swatch(_ act: StyleAction) { out.append((act, CGRect(x: x, y: y + pad, width: h, height: h))); x += h + 3 * k }
        func button(_ act: StyleAction, _ w: CGFloat = 32) { out.append((act, CGRect(x: x, y: y + pad, width: w * k, height: h))); x += w * k + 3 * k }
        switch a.kind {
        case .sticky:
            StickyColor.allCases.forEach { swatch(.stickyColor($0)) }; x += 6 * k
            ["bullet", "number", "none"].forEach { button(.list($0)) }
        case .arrow, .rect, .oval:
            StrokeColor.allCases.forEach { swatch(.stroke($0)) }; x += 6 * k
            LineWeight.allCases.forEach { button(.weight($0)) }; x += 3 * k
            button(.dashed)
        case .text:
            StrokeColor.allCases.forEach { swatch(.stroke($0)) }; x += 6 * k
            TextSize.allCases.forEach { button(.size($0), 28) }
        }
        // Keep the bar on screen.
        if let last = out.last?.1, let first = out.first?.1 {
            let shift = min(0, bounds.maxX - 16 - last.maxX) + max(0, 16 - (first.minX + min(0, bounds.maxX - 16 - last.maxX)))
            if shift != 0 { out = out.map { ($0.0, $0.1.offsetBy(dx: shift, dy: 0)) } }
        }
        return out
    }

    private func isActive(_ act: StyleAction, for a: Annotation) -> Bool {
        switch act {
        case .stickyColor(let c): return a.color == c.rawValue
        case .list(let l): return a.list == l
        case .stroke(let c): return a.stroke == c.rawValue
        case .weight(let w): return a.weight == w.rawValue
        case .dashed: return a.dashed
        case .size(let z): return a.size == z.rawValue
        }
    }

    private func drawStyleBar(for a: Annotation) {
        let items = styleBarItems(for: a)
        guard let first = items.first?.1, let last = items.last?.1 else { return }
        let bar = first.union(last).insetBy(dx: -6 * k, dy: -6 * k)
        NSColor.black.withAlphaComponent(0.85).setFill(); NSBezierPath(roundedRect: bar, xRadius: 8, yRadius: 8).fill()
        let labelAttrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 12 * max(k, 0.85), weight: .semibold), .foregroundColor: NSColor.white]
        func label(_ t: String, in r: CGRect) {
            let size = (t as NSString).size(withAttributes: labelAttrs)
            (t as NSString).draw(at: CGPoint(x: r.midX - size.width / 2, y: r.midY - size.height / 2), withAttributes: labelAttrs)
        }
        for (act, r) in items {
            let active = isActive(act, for: a)
            switch act {
            case .stickyColor(let c): swatch(c.nsColor, r, active)
            case .stroke(let c): swatch(c.nsColor, r, active)
            default: break
            }
            switch act {
            case .list(let l):
                if active { NSColor.white.withAlphaComponent(0.25).setFill(); NSBezierPath(roundedRect: r, xRadius: 6, yRadius: 6).fill() }
                label(l == "bullet" ? "•" : (l == "number" ? "1." : "Aa"), in: r)
            case .size(let z):
                if active { NSColor.white.withAlphaComponent(0.25).setFill(); NSBezierPath(roundedRect: r, xRadius: 6, yRadius: 6).fill() }
                label(z.label, in: r)
            case .weight(let w):
                if active { NSColor.white.withAlphaComponent(0.25).setFill(); NSBezierPath(roundedRect: r, xRadius: 6, yRadius: 6).fill() }
                NSColor.white.setStroke()
                let l = NSBezierPath(); l.lineWidth = w.points; l.lineCapStyle = .round
                l.move(to: CGPoint(x: r.minX + 8, y: r.midY)); l.line(to: CGPoint(x: r.maxX - 8, y: r.midY)); l.stroke()
            case .dashed:
                if active { NSColor.white.withAlphaComponent(0.25).setFill(); NSBezierPath(roundedRect: r, xRadius: 6, yRadius: 6).fill() }
                NSColor.white.setStroke()
                let l = NSBezierPath(); l.lineWidth = 2; l.setLineDash([4, 3], count: 2, phase: 0)
                l.move(to: CGPoint(x: r.minX + 7, y: r.midY)); l.line(to: CGPoint(x: r.maxX - 7, y: r.midY)); l.stroke()
            default: break
            }
        }
    }

    private func swatch(_ color: NSColor, _ r: CGRect, _ active: Bool) {
        color.setFill(); NSBezierPath(ovalIn: r.insetBy(dx: 2, dy: 2)).fill()
        NSColor.white.withAlphaComponent(0.35).setStroke(); NSBezierPath(ovalIn: r.insetBy(dx: 2, dy: 2)).stroke()
        if active { NSColor.white.setStroke(); let ring = NSBezierPath(ovalIn: r); ring.lineWidth = 2; ring.stroke() }
    }

    /// Applies a style choice to the selected item, keeping the text editor open if it was.
    private func applyStyleAction(_ act: StyleAction) {
        guard let id = selected else { return }
        let wasEditing = editor != nil
        endEditing()
        guard let i = index(id) else { return }
        switch act {
        case .stickyColor(let c): items[i].color = c.rawValue
        case .list(let l): items[i].list = l
        case .stroke(let c): items[i].stroke = c.rawValue
        case .weight(let w): items[i].weight = w.rawValue
        case .dashed: items[i].dashed.toggle()
        case .size(let z): items[i].size = z.rawValue
        }
        if wasEditing { beginEditing(id) }
        needsDisplay = true
    }

    private func hint(_ text: String) {
        let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 13 * max(k, 0.85), weight: .medium), .foregroundColor: NSColor.white]
        let size = (text as NSString).size(withAttributes: attrs)
        let r = CGRect(x: bounds.midX - size.width / 2 - 12 * k, y: topMargin, width: size.width + 24 * k, height: 30 * k)
        NSColor.black.withAlphaComponent(0.75).setFill(); NSBezierPath(roundedRect: r, xRadius: 8, yRadius: 8).fill()
        (text as NSString).draw(at: CGPoint(x: r.minX + 12 * k, y: r.midY - size.height / 2), withAttributes: attrs)
    }

    /// Button label: the name, then its keyboard key dimmed and smaller.
    private func buttonText(_ b: Button) -> NSAttributedString {
        let name = NSMutableAttributedString(string: b.name, attributes: [
            .font: NSFont.systemFont(ofSize: 12 * max(k, 0.85), weight: .medium), .foregroundColor: NSColor.white])
        if let key = b.key {
            name.append(NSAttributedString(string: "  " + key, attributes: [
                .font: NSFont.systemFont(ofSize: 10 * max(k, 0.85), weight: .regular), .foregroundColor: NSColor.white.withAlphaComponent(0.5)]))
        }
        return name
    }

    /// Toolbar geometry: a grip on the left (drag to move), then the buttons. Starts below the notch, shifted by the user's offset.
    private func toolbarLayout() -> (buttons: [(Button, CGRect)], bar: CGRect, grip: CGRect) {
        let gap: CGFloat = 2 * k, pad: CGFloat = 5 * k, padH: CGFloat = 9 * k, h: CGFloat = 26 * k, gripW: CGFloat = 12 * k
        let widths = Button.allCases.map { ceil(buttonText($0).size().width) + padH * 2 }
        let total = gripW + widths.reduce(0, +) + gap * CGFloat(widths.count - 1) + pad * 2
        let barH = h + pad * 2
        let baseX = bounds.midX - total / 2, baseY = topMargin
        let dx = min(max(toolbarOffset.width, 8 - baseX), bounds.width - 8 - total - baseX)
        let dy = min(max(toolbarOffset.height, topInset + 4 - baseY), bounds.height - barH - 8 - baseY)
        let bar = CGRect(x: baseX + dx, y: baseY + dy, width: total, height: barH)
        let grip = CGRect(x: bar.minX + pad, y: bar.minY, width: gripW, height: barH)
        var x = grip.maxX
        let buttons = zip(Button.allCases, widths).map { b, w -> (Button, CGRect) in
            defer { x += w + gap }
            return (b, CGRect(x: x, y: bar.minY + pad, width: w, height: h))
        }
        return (buttons, bar, grip)
    }

    private func toolbarRects() -> [(Button, CGRect)] { toolbarLayout().buttons }

    /// Where the toolbar would sit with no offset.
    private func toolbarLayoutBase() -> CGPoint {
        let saved = toolbarOffset
        toolbarOffset = .zero
        defer { toolbarOffset = saved }
        let l = toolbarLayout()
        return l.bar.origin
    }

    private func drawToolbar() {
        let layout = toolbarLayout()
        NSColor.black.withAlphaComponent(0.8).setFill(); NSBezierPath(roundedRect: layout.bar, xRadius: 9, yRadius: 9).fill()
        // Grip: two columns of dots.
        NSColor.white.withAlphaComponent(0.4).setFill()
        for col in 0..<2 { for row in 0..<3 {
            let dot = CGRect(x: layout.grip.midX - 3.5 * k + CGFloat(col) * 5 * k, y: layout.grip.midY - 7 * k + CGFloat(row) * 5 * k, width: 2.5 * k, height: 2.5 * k)
            NSBezierPath(ovalIn: dot).fill()
        } }
        for (b, r) in layout.buttons {
            let active = (b == .arrow && tool == .arrow) || (b == .rect && tool == .rect) || (b == .oval && tool == .oval) || (b == .text && tool == .text) || (b == .select && tool == .select)
            if active { NSColor.white.withAlphaComponent(0.25).setFill(); NSBezierPath(roundedRect: r, xRadius: 6, yRadius: 6).fill() }
            if b == .done { NSColor.systemBlue.setFill(); NSBezierPath(roundedRect: r, xRadius: 6, yRadius: 6).fill() }
            let t = buttonText(b), size = t.size()
            t.draw(at: CGPoint(x: r.midX - size.width / 2, y: r.midY - size.height / 2))
        }
    }

    // MARK: Mouse

    override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        dragStart = p
        if window?.firstResponder !== self, editor == nil { window?.makeFirstResponder(self) }   // leave the trim fields
        if phase == .selecting {
            drag = .select(start: p); selection = CGRect(origin: p, size: .zero); needsDisplay = true; return
        }
        if filmstripRect()?.contains(p) == true { return }
        if let (b, _) = toolbarRects().first(where: { $0.1.insetBy(dx: -3, dy: -3).contains(p) }) {
            toolbarClick(b, at: p); return
        }
        let layout = toolbarLayout()
        if layout.bar.contains(p) {
            // Anywhere on the bar that is not a button moves it; double-click the grip to put it back.
            if event.clickCount == 2, layout.grip.contains(p) { toolbarOffset = .zero; Prefs.toolbarOffset = .zero; needsDisplay = true; return }
            drag = .moveToolbar(startMouse: p, startOffset: toolbarOffset); return
        }
        if let a = selectedItem, let hit = styleBarItems(for: a).first(where: { $0.1.insetBy(dx: -2, dy: -2).contains(p) }) {
            applyStyleAction(hit.0); return
        }
        if let h = handle(at: p), let sel = selection { endEditing(); drag = .resize(handle: h, original: sel); return }
        endEditing()
        if tool == .rect || tool == .oval {
            let a = Annotation(kind: tool == .rect ? .rect : .oval, x: p.x, y: p.y, x2: p.x, y2: p.y)
            items.append(a); selected = a.id; drag = .newShape(id: a.id, origin: p)
        } else if tool == .text {
            let a = Annotation(kind: .text, x: p.x, y: p.y, x2: p.x + 240, stroke: "black")
            items.append(a); selected = a.id; tool = .select
            beginEditing(a.id)
        } else if tool == .arrow {
            let a = Annotation(kind: .arrow, x: p.x, y: p.y, x2: p.x, y2: p.y)
            items.append(a); selected = a.id; drag = .newArrow(id: a.id)
        } else if let sh = selectedShape, let corner = corners4(shapeRect(sh)).enumerated().first(where: { hypot($0.element.x - p.x, $0.element.y - p.y) < 10 }) {
            let opposite = corners4(shapeRect(sh))[(corner.offset + 2) % 4]
            drag = .shapeCorner(id: sh.id, anchor: opposite)
        } else if let hit = annotation(at: p) {
            selected = hit.id
            if event.clickCount == 2, hit.kind == .sticky || hit.kind == .text { beginEditing(hit.id) }
            else if hit.kind == .arrow, let end = nearEndpoint(hit, p) { drag = .endpoint(id: hit.id, end: end) }
            else { drag = .move(id: hit.id, last: p) }
        } else { selected = nil; drag = .none }
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        switch drag {
        case .select(let start): selection = CGRect(x: min(start.x, p.x), y: min(start.y, p.y), width: abs(p.x - start.x), height: abs(p.y - start.y))
        case .resize(let h, let o):
            let r = resized(o, h, to: p)
            if r != selection { usedAuto = false; usedReset = false }
            selection = r; syncInspector()
        case .move(let id, let last):
            if let i = index(id) {
                let dx = p.x - last.x, dy = p.y - last.y
                items[i].x += dx; items[i].y += dy
                if items[i].kind != .sticky { items[i].x2 += dx; items[i].y2 += dy }
            }
            drag = .move(id: id, last: p)
        case .endpoint(let id, let end):
            if let i = index(id) { if end == 0 { items[i].x = p.x; items[i].y = p.y } else { items[i].x2 = p.x; items[i].y2 = p.y } }
        case .newArrow(let id): if let i = index(id) { items[i].x2 = p.x; items[i].y2 = p.y }
        case .moveToolbar(let m, let o): toolbarOffset = CGSize(width: o.width + p.x - m.x, height: o.height + p.y - m.y)
        case .newShape(let id, let o): if let i = index(id) { setShape(i, shapeBounds(from: o, to: p, square: event.modifierFlags.contains(.shift))) }
        case .shapeCorner(let id, let anchor): if let i = index(id) { setShape(i, shapeBounds(from: anchor, to: p, square: event.modifierFlags.contains(.shift))) }
        case .newSticky(let id, let grab): if let i = index(id) { items[i].x = p.x - grab.x; items[i].y = p.y - grab.y }
        case .none: break
        }
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        switch drag {
        case .select:
            if let s = selection, s.width > 10, s.height > 10 { phase = .annotating; inspector.isHidden = false; syncInspector(); window?.invalidateCursorRects(for: self) }
            else { selection = nil }
        case .newArrow(let id):
            if let i = index(id), hypot(items[i].x2 - items[i].x, items[i].y2 - items[i].y) < 10 { items.remove(at: i); selected = nil }
        case .moveToolbar:
            // Save the clamped position so the next capture opens the toolbar where it was left.
            let l = toolbarLayout(), base = toolbarLayoutBase()
            toolbarOffset = CGSize(width: l.bar.minX - base.x, height: l.bar.minY - base.y)
            Prefs.toolbarOffset = toolbarOffset
        case .newShape(let id, _):
            if let i = index(id) {
                let r = shapeRect(items[i])
                if r.width < 8 || r.height < 8 { items.remove(at: i); selected = nil } else { tool = .select }
            }
        case .newSticky(let id, _):
            // A click (no drag) on the toolbar button drops the sticky in the middle of the selection instead of under the toolbar.
            let p = convert(event.locationInWindow, from: nil)
            if hypot(p.x - dragStart.x, p.y - dragStart.y) < 4, let i = index(id), let sel = selection {
                items[i].x = sel.midX - sw / 2; items[i].y = sel.midY - sh / 2
            }
            beginEditing(id)
        default: break
        }
        drag = .none; needsDisplay = true
    }

    private func toolbarClick(_ b: Button, at p: CGPoint) {
        switch b {
        case .sticky:
            let a = Annotation(kind: .sticky, x: p.x - sw / 2, y: p.y - sh / 2)
            items.append(a); selected = a.id; tool = .select; drag = .newSticky(id: a.id, grab: CGPoint(x: sw / 2, y: sh / 2))
        case .arrow: tool = .arrow
        case .rect: tool = .rect
        case .oval: tool = .oval
        case .text: tool = .text
        case .select: tool = .select
        case .more: showMoreMenu()
        case .done: finish()
        case .cancel: onCancel?()
        }
        needsDisplay = true
    }

    /// Rarely used actions live behind the ••• button so the toolbar stays short.
    private func showMoreMenu() {
        guard let r = toolbarRects().first(where: { $0.0 == .more })?.1 else { return }
        let menu = NSMenu()
        let item = NSMenuItem(title: "Draw a New Area   N", action: #selector(reselectFromMenu), keyEquivalent: "")
        item.target = self
        menu.addItem(item)
        menu.popUp(positioning: nil, at: CGPoint(x: r.minX, y: r.maxY + 10), in: self)
    }

    @objc private func reselectFromMenu() { reselect(); needsDisplay = true }

    /// Start a fresh selection; annotations already placed stay where they are.
    private func reselect() {
        endEditing()
        phase = .selecting; selection = nil; inspector.isHidden = true
        window?.invalidateCursorRects(for: self)
    }

    // MARK: Hit testing

    private func index(_ id: UUID?) -> Int? { items.firstIndex { $0.id == id } }

    private func annotation(at p: CGPoint) -> Annotation? {
        items.last { a in
            switch a.kind {
            case .sticky: return CGRect(x: a.x, y: a.y, width: sw, height: sh).contains(p)
            case .arrow: return distance(p, toSegment: CGPoint(x: a.x, y: a.y), CGPoint(x: a.x2, y: a.y2)) < 8
            case .rect, .oval: return outlineDistance(p, a) < 8
            case .text: return textRect(a).insetBy(dx: -4, dy: -4).contains(p)
            }
        }
    }

    private var selectedShape: Annotation? {
        guard let i = index(selected), items[i].kind == .rect || items[i].kind == .oval else { return nil }
        return items[i]
    }

    private func nearEndpoint(_ a: Annotation, _ p: CGPoint) -> Int? {
        if hypot(p.x - a.x, p.y - a.y) < 12 { return 0 }
        if hypot(p.x - a.x2, p.y - a.y2) < 12 { return 1 }
        return nil
    }

    private func distance(_ p: CGPoint, toSegment a: CGPoint, _ b: CGPoint) -> CGFloat {
        let dx = b.x - a.x, dy = b.y - a.y, len2 = dx * dx + dy * dy
        guard len2 > 0 else { return hypot(p.x - a.x, p.y - a.y) }
        let t = max(0, min(1, ((p.x - a.x) * dx + (p.y - a.y) * dy) / len2))
        return hypot(p.x - (a.x + t * dx), p.y - (a.y + t * dy))
    }

    // MARK: Text editing

    private func beginEditing(_ id: UUID) {
        endEditing()
        guard let i = index(id) else { return }
        let a = items[i]
        let f: NSTextField
        if a.kind == .text {
            let r = textRect(a)
            f = NSTextField(frame: CGRect(x: r.minX, y: r.minY, width: r.width, height: max(r.height, 32)))
            f.font = textFont(a); f.textColor = strokeColor(a)
            f.placeholderString = "Type text…"
        } else {
            f = NSTextField(frame: CGRect(x: a.x + 10, y: a.y + 10, width: sw - 20, height: sh - 20))
            f.font = .systemFont(ofSize: stickyFont); f.textColor = .black
            f.placeholderString = "Type a note…"
        }
        f.stringValue = a.text
        f.isBordered = false; f.drawsBackground = false; f.focusRingType = .none
        f.cell?.wraps = true; f.cell?.isScrollable = false
        f.delegate = self
        addSubview(f)
        window?.makeFirstResponder(f)
        editor = f; editingID = id; selected = id
        needsDisplay = true
    }

    private func endEditing() {
        guard let f = editor else { return }
        editor = nil
        if let i = index(editingID) {
            items[i].text = f.stringValue
            // A text box left empty is discarded.
            if items[i].kind == .text, f.stringValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { items.remove(at: i); selected = nil }
        }
        editingID = nil
        f.removeFromSuperview()
        window?.makeFirstResponder(self)
        needsDisplay = true
    }

    func controlTextDidEndEditing(_ obj: Notification) { endEditing() }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy sel: Selector) -> Bool {
        if sel == #selector(cancelOperation(_:)) { endEditing(); return true }
        // Return finishes the note; Shift+Return adds a new line.
        if sel == #selector(insertNewline(_:)), NSApp.currentEvent?.modifierFlags.contains(.shift) == true {
            textView.insertNewlineIgnoringFieldEditor(nil); return true
        }
        return false
    }

    // MARK: Keys

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 53: onCancel?()                                   // esc
        case 36: if phase == .annotating { finish() }          // return
        case 51, 117:                                          // delete
            if let i = index(selected) { items.remove(at: i); selected = nil }
        default:
            guard phase == .annotating else { return }
            switch event.charactersIgnoringModifiers?.lowercased() {
            case "a": tool = .arrow
            case "v": tool = .select
            case "r": tool = .rect
            case "o": tool = .oval
            case "t": tool = .text
            case "n": reselect()
            case "e": if !inspector.isHidden { inspector.expand(focus: true) }
            case "s":
                let p = convert(window?.mouseLocationOutsideOfEventStream ?? .zero, from: nil)
                let a = Annotation(kind: .sticky, x: p.x - sw / 2, y: p.y - sh / 2)
                items.append(a); beginEditing(a.id)
            default: break
            }
        }
        needsDisplay = true
    }

    private func finish() {
        endEditing()
        inspector.commitEditing()   // apply anything still being typed in the trim fields before reading the selection
        guard let sel = selection, phase == .annotating else { onCancel?(); return }
        let t = trim(for: sel)
        let clamped = t.map { Margins(top: max(0, $0.top), right: max(0, $0.right), bottom: max(0, $0.bottom), left: max(0, $0.left)) }
        let edited = t.map { abs($0.top - initialTrim.top) > 0.5 || abs($0.right - initialTrim.right) > 0.5
                              || abs($0.bottom - initialTrim.bottom) > 0.5 || abs($0.left - initialTrim.left) > 0.5 } ?? false
        let outcome = Outcome(radius: corners.radius, trim: clamped, trimEdited: edited,
                              radiusEdited: abs(corners.radius - initialRadius) > 0.5,
                              usedAuto: usedAuto, usedReset: usedReset, remember: rememberOn)
        onDone?(sel, items, outcome)
    }
}

// MARK: - Trim & corners panel

/// Compact panel inside the overlay. Collapsed it is a one-line preview of the trim and radius; click it (or press E)
/// to expand the editable fields. ↑/↓ step a number by 1 (Shift: 10); Tab moves between fields.
private final class InspectorView: NSView, NSTextFieldDelegate {
    var onChange: (() -> Void)?
    var onFocusBack: (() -> Void)?
    var onQuick: (() -> Void)?
    var onRemember: ((Bool) -> Void)?

    private let k: CGFloat
    private let showTrim: Bool
    private var trimFields: [NSTextField] = []      // top, right, bottom, left
    private var trimCaptions: [NSTextField] = []
    private let radiusField: NSTextField
    private var radiusCaption: NSTextField!
    private var title: NSTextField!
    private let remember: NSButton
    private var chevron: NSButton!
    private var quick: NSButton?
    private var collapsed = true
    private var summary = ""

    override var isFlipped: Bool { true }

    init(scale: CGFloat, showTrim: Bool, quickTitle: String?, rememberTitle: String, rememberOn: Bool) {
        k = scale; self.showTrim = showTrim
        radiusField = InspectorView.field(scale)
        remember = NSButton(checkboxWithTitle: rememberTitle, target: nil, action: nil)
        super.init(frame: .zero)
        build(quickTitle: quickTitle, rememberTitle: rememberTitle, rememberOn: rememberOn)
        applyLayout()
    }
    required init?(coder: NSCoder) { fatalError() }

    private func font(_ s: CGFloat = 11, _ w: NSFont.Weight = .regular) -> NSFont { .systemFont(ofSize: s * max(k, 0.85), weight: w) }

    private static func field(_ k: CGFloat) -> NSTextField {
        let f = NSTextField(frame: NSRect(x: 0, y: 0, width: 38 * k, height: 20 * k))
        f.isBezeled = true; f.bezelStyle = .roundedBezel; f.controlSize = .mini
        f.font = .monospacedDigitSystemFont(ofSize: 11 * max(k, 0.85), weight: .regular); f.alignment = .center
        return f
    }

    private func label(_ text: String, width: CGFloat) -> NSTextField {
        let l = NSTextField(labelWithString: text)
        l.textColor = NSColor.white.withAlphaComponent(0.75); l.font = font(11, .medium)
        l.frame.size = NSSize(width: width, height: 14 * k)
        return l
    }

    private var expandedViews: [NSView] {
        [title, chevron, radiusCaption, radiusField, remember] + trimCaptions + trimFields + (quick.map { [$0] } ?? [])
    }

    private func build(quickTitle: String?, rememberTitle: String, rememberOn: Bool) {
        title = label("Trim & corners", width: 110 * k)
        chevron = NSButton(title: "▴", target: self, action: #selector(collapse))
        chevron.isBordered = false
        chevron.attributedTitle = NSAttributedString(string: "▴", attributes: [.foregroundColor: NSColor.white, .font: font(11, .bold)])
        if showTrim {
            for name in ["T", "R", "B", "L"] {
                trimCaptions.append(label(name, width: 10 * k))
                let f = InspectorView.field(k); f.delegate = self; f.target = self; f.action = #selector(committed)
                trimFields.append(f)
            }
        }
        radiusCaption = label("Radius", width: 40 * k)
        radiusField.delegate = self; radiusField.target = self; radiusField.action = #selector(committed)
        if let quickTitle {
            let b = NSButton(title: quickTitle, target: self, action: #selector(quickTapped))
            b.bezelStyle = .rounded; b.controlSize = .mini; b.font = font(10)
            quick = b
        }
        remember.target = self; remember.action = #selector(rememberToggled)
        remember.state = rememberOn ? .on : .off
        remember.controlSize = .mini
        remember.attributedTitle = NSAttributedString(string: rememberTitle, attributes: [.foregroundColor: NSColor.white, .font: font(11)])
        expandedViews.forEach(addSubview)
    }

    /// Positions everything for the current collapsed / expanded state.
    private func applyLayout() {
        expandedViews.forEach { $0.isHidden = collapsed }
        if collapsed {
            let w = ceil((summary as NSString).size(withAttributes: [.font: font(11, .medium)]).width) + 32 * k
            setFrameSize(NSSize(width: max(w, 150 * k), height: 24 * k))
        } else {
            let pad = 10 * k
            let width = (showTrim ? 4 * 54 * k + pad * 2 : 220 * k)
            var y = 6 * k
            title.frame.origin = CGPoint(x: pad, y: y)
            chevron.frame = NSRect(x: width - 26 * k, y: y - 3 * k, width: 20 * k, height: 18 * k)
            y += 22 * k
            if showTrim {
                var x = pad
                for (cap, f) in zip(trimCaptions, trimFields) {
                    cap.frame.origin = CGPoint(x: x, y: y + 3 * k)
                    f.frame.origin = CGPoint(x: x + 11 * k, y: y); x += 54 * k
                }
                y += 26 * k
            }
            radiusCaption.frame.origin = CGPoint(x: pad, y: y + 3 * k)
            radiusField.frame.origin = CGPoint(x: pad + 42 * k, y: y)
            quick?.frame = NSRect(x: pad + 88 * k, y: y, width: 50 * k, height: 20 * k)
            y += 26 * k
            remember.frame = NSRect(x: pad, y: y, width: width - pad * 2, height: 16 * k)
            y += 22 * k
            setFrameSize(NSSize(width: width, height: y))
        }
        needsDisplay = true
    }

    override func draw(_ dirty: NSRect) {
        NSColor.black.withAlphaComponent(0.8).setFill()
        let r = collapsed ? bounds.height / 2 : 9
        NSBezierPath(roundedRect: bounds, xRadius: r, yRadius: r).fill()
        guard collapsed else { return }
        let attrs: [NSAttributedString.Key: Any] = [.font: font(11, .medium), .foregroundColor: NSColor.white]
        let size = (summary as NSString).size(withAttributes: attrs)
        (summary as NSString).draw(at: CGPoint(x: 12 * k, y: (bounds.height - size.height) / 2), withAttributes: attrs)
        ("▾" as NSString).draw(at: CGPoint(x: bounds.width - 18 * k, y: (bounds.height - size.height) / 2), withAttributes: attrs)
    }

    override func mouseDown(with event: NSEvent) { if collapsed { expand(focus: true) } else { super.mouseDown(with: event) } }

    func expand(focus: Bool) {
        if collapsed { collapsed = false; applyLayout() }
        if focus { window?.makeFirstResponder(trimFields.first ?? radiusField) }
    }

    @objc private func collapse() {
        window?.makeFirstResponder(nil); onChange?()
        collapsed = true; applyLayout()
        onFocusBack?()
    }

    /// Shows values without disturbing a field the user is typing in, and refreshes the one-line preview.
    func show(trim: Margins?, radius: CGFloat) {
        func set(_ f: NSTextField, _ v: Double) { if f.currentEditor() == nil { f.stringValue = String(Int(v.rounded())) } }
        if let t = trim, trimFields.count == 4 {
            set(trimFields[0], t.top); set(trimFields[1], t.right); set(trimFields[2], t.bottom); set(trimFields[3], t.left)
            summary = "Trim \(Int(t.top.rounded())) · \(Int(t.right.rounded())) · \(Int(t.bottom.rounded())) · \(Int(t.left.rounded()))   R \(Int(radius.rounded()))"
        } else {
            summary = "Corner radius \(Int(radius.rounded()))"
        }
        set(radiusField, Double(radius))
        if collapsed { applyLayout() }
    }

    func values() -> (trim: Margins?, radius: Double) {
        func v(_ f: NSTextField) -> Double { Double(f.stringValue.trimmingCharacters(in: .whitespaces)) ?? 0 }
        let t: Margins? = showTrim && trimFields.count == 4
            ? Margins(top: v(trimFields[0]), right: v(trimFields[1]), bottom: v(trimFields[2]), left: v(trimFields[3])) : nil
        return (t, v(radiusField))
    }

    /// Applies whatever is still being typed (used when Done is pressed mid-edit).
    func commitEditing() { window?.makeFirstResponder(nil); onChange?() }

    @objc private func committed() { onChange?(); onFocusBack?() }
    @objc private func quickTapped() { onQuick?() }
    @objc private func rememberToggled() { onRemember?(remember.state == .on) }

    func controlTextDidEndEditing(_ obj: Notification) { onChange?() }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy sel: Selector) -> Bool {
        if sel == #selector(cancelOperation(_:)) { onFocusBack?(); return true }
        // ↑ / ↓ step the number (Shift = 10), like a stepper.
        let up = sel == #selector(moveUp(_:)) || sel == #selector(moveUpAndModifySelection(_:))
        let down = sel == #selector(moveDown(_:)) || sel == #selector(moveDownAndModifySelection(_:))
        if (up || down), let f = control as? NSTextField {
            let step = (NSApp.currentEvent?.modifierFlags.contains(.shift) == true ? 10 : 1) * (up ? 1 : -1)
            let next = (Int(f.stringValue.trimmingCharacters(in: .whitespaces)) ?? 0) + step
            f.stringValue = String(f === radiusField ? max(0, next) : next)
            textView.selectAll(nil)
            onChange?()
            return true
        }
        return false
    }
}
