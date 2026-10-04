import AppKit

/// Corner thumbnail of the latest step in the open flow, plus a larger preview window with ←/→ navigation.
final class PreviewHUD {
    static let shared = PreviewHUD()
    private var panel: NSPanel?
    private var thumb: ThumbView?
    private var preview: PreviewWindow?

    /// Call whenever the open flow changes (capture saved, flow finished) or after the overlay closes.
    func refresh() {
        let recs = Store.shared.openFlowRecords()
        guard let last = recs.last, let img = NSImage(contentsOf: Store.shared.imageURL(for: last.id)) else {
            panel?.orderOut(nil); closePreview(); return
        }
        if panel == nil {
            let p = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            p.level = .floating
            p.isOpaque = false; p.backgroundColor = .clear; p.hasShadow = true
            p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            p.isMovableByWindowBackground = false
            let t = ThumbView(); t.onClick = { [weak self] in self?.openPreview() }
            p.contentView = t
            panel = p; thumb = t
        }
        thumb?.set(image: img, count: recs.count)
        let size = thumb!.fittingSize
        if let screen = NSScreen.main ?? NSScreen.screens.first {
            let v = screen.visibleFrame
            panel?.setFrame(NSRect(x: v.maxX - size.width - 16, y: v.minY + 16, width: size.width, height: size.height), display: true)
        }
        panel?.orderFrontRegardless()
        preview?.content.reload()
    }

    /// Hides everything so the corner thumbnail never appears in a freshly captured screenshot.
    func hideForCapture() {
        panel?.orderOut(nil)
        closePreview()
        usleep(80_000)
    }

    func openPreview() {
        guard !Store.shared.openFlowRecords().isEmpty else { return NSSound.beep() }
        if preview == nil { preview = PreviewWindow() }
        preview?.content.showLast()
        preview?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func closePreview() { preview?.orderOut(nil); preview = nil }
}

private final class ThumbView: NSView {
    var onClick: (() -> Void)?
    private var image: NSImage?
    private var count = 0
    private let h: CGFloat = 96

    override var isFlipped: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with event: NSEvent) { onClick?() }

    func set(image: NSImage, count: Int) { self.image = image; self.count = count; needsDisplay = true }

    override var fittingSize: NSSize {
        guard let img = image else { return NSSize(width: 120, height: h) }
        return NSSize(width: min(200, max(60, h * img.size.width / max(img.size.height, 1))), height: h)
    }

    override func draw(_ dirty: NSRect) {
        guard let img = image else { return }
        let r = bounds.insetBy(dx: 1, dy: 1)
        NSGraphicsContext.saveGraphicsState()
        NSBezierPath(roundedRect: r, xRadius: 8, yRadius: 8).addClip()
        img.draw(in: r)
        NSGraphicsContext.restoreGraphicsState()
        NSColor.white.withAlphaComponent(0.8).setStroke()
        NSBezierPath(roundedRect: r, xRadius: 8, yRadius: 8).stroke()

        let text = "Step \(count)  ·  click to preview" as NSString
        let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 10, weight: .semibold), .foregroundColor: NSColor.white]
        let size = text.size(withAttributes: attrs)
        let pill = CGRect(x: r.minX + 6, y: r.maxY - size.height - 10, width: min(size.width + 12, r.width - 12), height: size.height + 6)
        NSColor.black.withAlphaComponent(0.7).setFill(); NSBezierPath(roundedRect: pill, xRadius: 6, yRadius: 6).fill()
        text.draw(at: CGPoint(x: pill.minX + 6, y: pill.minY + 3), withAttributes: attrs)
    }
}

private final class PreviewWindow: NSPanel {
    let content = StepPreviewView()
    override var canBecomeKey: Bool { true }

    init() {
        let screen = (NSScreen.main ?? NSScreen.screens[0]).visibleFrame
        let size = NSSize(width: screen.width * 0.6, height: screen.height * 0.7)
        super.init(contentRect: NSRect(x: screen.midX - size.width / 2, y: screen.midY - size.height / 2, width: size.width, height: size.height),
                   styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        level = .floating
        isReleasedWhenClosed = false
        contentView = content
        content.reload()
    }
}

/// Draws one step: the clean screenshot with its stickies and arrows scaled on top.
private final class StepPreviewView: NSView {
    private var records: [CaptureRecord] = []
    private var index = 0

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override func viewDidMoveToWindow() { window?.makeFirstResponder(self) }

    func reload() {
        records = Store.shared.openFlowRecords()
        index = min(index, max(records.count - 1, 0))
        update()
    }

    func showLast() { records = Store.shared.openFlowRecords(); index = max(records.count - 1, 0); update() }

    private func update() {
        window?.title = records.isEmpty ? "Flow preview" : "Step \(index + 1) of \(records.count)"
        needsDisplay = true
    }

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 123: if index > 0 { index -= 1; update() }                       // ←
        case 124: if index < records.count - 1 { index += 1; update() }       // →
        case 53: window?.orderOut(nil)                                        // esc
        default: break
        }
    }

    override func draw(_ dirty: NSRect) {
        NSColor(calibratedWhite: 0.12, alpha: 1).setFill(); bounds.fill()
        guard index < records.count else { return }
        let rec = records[index]
        guard let img = NSImage(contentsOf: Store.shared.imageURL(for: rec.id)) else { return }

        let avail = CGRect(x: 24, y: 24, width: bounds.width - 48, height: bounds.height - 24 - 44)
        let k = min(avail.width / rec.width, avail.height / rec.height)
        let fit = CGRect(x: avail.midX - rec.width * k / 2, y: avail.midY - rec.height * k / 2, width: rec.width * k, height: rec.height * k)
        img.draw(in: fit)

        let sw = FigJamMetrics.stickyWidth * k, sh = FigJamMetrics.stickyHeight * k
        for a in rec.annotations {
            let stroke = (StrokeColor(rawValue: a.stroke) ?? .red).nsColor
            let lw = (LineWeight(rawValue: a.weight) ?? .medium).points * max(k, 0.6)
            func dashed(_ p: NSBezierPath) { if a.dashed { p.setLineDash([lw * 3, lw * 2], count: 2, phase: 0) } }
            switch a.kind {
            case .sticky:
                let r = CGRect(x: fit.minX + a.x * k, y: fit.minY + a.y * k, width: sw, height: sh)
                (StickyColor(rawValue: a.color) ?? .yellow).nsColor.setFill()
                NSBezierPath(roundedRect: r, xRadius: 4 * k, yRadius: 4 * k).fill()
                StickyStyle.attributed(a, fontSize: 20 * k).draw(in: r.insetBy(dx: 10 * k, dy: 10 * k))
            case .rect, .oval:
                let r = CGRect(x: fit.minX + min(a.x, a.x2) * k, y: fit.minY + min(a.y, a.y2) * k, width: abs(a.x2 - a.x) * k, height: abs(a.y2 - a.y) * k)
                stroke.setStroke()
                let path = a.kind == .oval ? NSBezierPath(ovalIn: r) : NSBezierPath(rect: r)
                path.lineWidth = lw; dashed(path); path.stroke()
            case .text:
                let size = (TextSize(rawValue: a.size) ?? .medium).points * k
                let r = CGRect(x: fit.minX + a.x * k, y: fit.minY + a.y * k, width: max(40, a.x2 - a.x) * k, height: 10_000)
                NSAttributedString(string: a.text, attributes: [.font: NSFont.systemFont(ofSize: size), .foregroundColor: stroke])
                    .draw(with: r, options: [.usesLineFragmentOrigin])
            case .arrow:
                let s = CGPoint(x: fit.minX + a.x * k, y: fit.minY + a.y * k), e = CGPoint(x: fit.minX + a.x2 * k, y: fit.minY + a.y2 * k)
                stroke.setStroke()
                let shaft = NSBezierPath(); shaft.lineWidth = lw; shaft.lineCapStyle = .round
                shaft.move(to: s); shaft.line(to: e); dashed(shaft); shaft.stroke()
                let head = NSBezierPath(); head.lineWidth = lw; head.lineCapStyle = .round
                let ang = atan2(e.y - s.y, e.x - s.x), len = (10 + 2 * lw)
                for d in [CGFloat.pi * 0.8, -CGFloat.pi * 0.8] {
                    head.move(to: e); head.line(to: CGPoint(x: e.x + len * cos(ang + d), y: e.y + len * sin(ang + d)))
                }
                head.stroke()
            }
        }

        let hint = "←  →  navigate   ·   Esc  close" as NSString
        let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 12), .foregroundColor: NSColor.white.withAlphaComponent(0.6)]
        let size = hint.size(withAttributes: attrs)
        hint.draw(at: CGPoint(x: bounds.midX - size.width / 2, y: bounds.maxY - 28), withAttributes: attrs)
    }
}
