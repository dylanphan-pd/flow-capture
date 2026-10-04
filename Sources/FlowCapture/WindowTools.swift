import AppKit
import ApplicationServices

/// Per-app crop margins (points) that strip browser chrome, and window snapping to viewport presets.
struct Margins: Codable, Equatable {
    var top = 0.0, right = 0.0, bottom = 0.0, left = 0.0
    var radius = 0.0   // corner radius (points) applied to the exported screenshot
    /// True once the user set the trim by hand in the overlay; stops live measurement from overriding it.
    var pinned = false

    init(top: Double = 0, right: Double = 0, bottom: Double = 0, left: Double = 0, radius: Double = 0, pinned: Bool = false) {
        self.top = top; self.right = right; self.bottom = bottom; self.left = left; self.radius = radius; self.pinned = pinned
    }

    // Older saved margins have no `radius` / `pinned`.
    init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        top = try c.decode(Double.self, forKey: .top); right = try c.decode(Double.self, forKey: .right)
        bottom = try c.decode(Double.self, forKey: .bottom); left = try c.decode(Double.self, forKey: .left)
        radius = try c.decodeIfPresent(Double.self, forKey: .radius) ?? 0
        pinned = try c.decodeIfPresent(Bool.self, forKey: .pinned) ?? false
    }

    /// Built-in defaults for apps with a known frame; anything the user saves overrides these.
    static let builtIn: [String: Margins] = [
        "com.apple.ScreenContinuity": Margins(top: 38, right: 8, bottom: 8, left: 8, radius: 48), // iPhone Mirroring
    ]

    /// Trim for Chromium app-mode ("clean") windows. Adjustable in the capture overlay.
    static let cleanWindowDefault = Margins(top: 32, right: 1, bottom: 1, left: 1, radius: 18)

    static func loadClean() -> Margins {
        guard let data = UserDefaults.standard.data(forKey: "margins.cleanWindow"),
              let m = try? JSONDecoder().decode(Margins.self, from: data) else { return cleanWindowDefault }
        return m
    }

    func saveClean() {
        if let data = try? JSONEncoder().encode(self) { UserDefaults.standard.set(data, forKey: "margins.cleanWindow") }
    }

    static func load(bundleID: String) -> Margins {
        guard let data = UserDefaults.standard.data(forKey: "margins.\(bundleID)"),
              let m = try? JSONDecoder().decode(Margins.self, from: data) else { return builtIn[bundleID] ?? Margins() }
        return m
    }

    func save(bundleID: String) {
        if let data = try? JSONEncoder().encode(self) { UserDefaults.standard.set(data, forKey: "margins.\(bundleID)") }
    }
}

struct SizePreset { let name: String; let width: Double; let height: Double }

enum WindowTools {
    static let presets = [
        SizePreset(name: "Mobile 390×844", width: 390, height: 844),
        SizePreset(name: "Tablet 768×1024", width: 768, height: 1024),
        SizePreset(name: "Laptop 1280×800", width: 1280, height: 800),
        SizePreset(name: "Desktop 1440×900", width: 1440, height: 900),
        SizePreset(name: "Full HD 1920×1080", width: 1920, height: 1080),
    ]

    static func ensureAccessibility() -> Bool {
        let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        return AXIsProcessTrustedWithOptions(opts)
    }

    /// A browser window with no tabs/address bar (only a title bar above the page) is a clean/app-mode window.
    /// The lower bound keeps fullscreen browsers (page starts at the very top) from matching.
    private static func looksClean(top: Double) -> Bool { top >= 10 && top < 60 }

    static func isCleanWindow(_ app: NSRunningApplication) -> Bool {
        guard let v = measureViewport(of: app) else { return false }
        return looksClean(top: v.top)
    }

    struct EffectiveMargins { var margins: Margins; var isClean: Bool; var canAuto: Bool }

    /// Trim to use for this app's frontmost window: the clean-window preset, a trim the user pinned,
    /// the live-measured page area, or the saved/built-in values (in that order).
    static func effective(for app: NSRunningApplication) -> EffectiveMargins {
        guard let id = app.bundleIdentifier else { return EffectiveMargins(margins: Margins(), isClean: false, canAuto: false) }
        let live = measureViewport(of: app)
        if let v = live, looksClean(top: v.top) { return EffectiveMargins(margins: Margins.loadClean(), isClean: true, canAuto: false) }
        var m = Margins.load(bundleID: id)
        if let v = live, !m.pinned { m.top = v.top; m.right = v.right; m.bottom = v.bottom; m.left = v.left }
        return EffectiveMargins(margins: m, isClean: false, canAuto: live != nil)
    }

    static func effectiveMargins(for app: NSRunningApplication) -> Margins { effective(for: app).margins }

    /// Page size last applied to this app by a preset, if any.
    static func lastPreset(bundleID: String) -> CGSize? {
        guard let v = UserDefaults.standard.array(forKey: "preset.\(bundleID)") as? [Double], v.count == 2 else { return nil }
        return CGSize(width: v[0], height: v[1])
    }

    struct WindowInfo { let id: CGWindowID; let bounds: CGRect }

    /// Frontmost normal window of `app`, in global screen points (origin top-left).
    static func windowInfo(of app: NSRunningApplication) -> WindowInfo? {
        let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]]
        for w in list ?? [] {
            guard (w[kCGWindowOwnerPID as String] as? Int32) == app.processIdentifier,
                  (w[kCGWindowLayer as String] as? Int) == 0,
                  let num = w[kCGWindowNumber as String] as? UInt32,
                  let dict = w[kCGWindowBounds as String] as? NSDictionary,
                  let rect = CGRect(dictionaryRepresentation: dict), rect.width > 50 else { continue }
            return WindowInfo(id: num, bounds: rect) // list is front-to-back, so first match is the frontmost window
        }
        return nil
    }

    static func windowBounds(of app: NSRunningApplication) -> CGRect? { windowInfo(of: app)?.bounds }

    // MARK: Measuring

    private static func attr(_ e: AXUIElement, _ a: String) -> CFTypeRef? {
        var v: CFTypeRef?
        return AXUIElementCopyAttributeValue(e, a as CFString, &v) == .success ? v : nil
    }

    private static func frame(_ e: AXUIElement) -> CGRect? {
        var p = CGPoint.zero, s = CGSize.zero
        guard let pv = attr(e, kAXPositionAttribute), let sv = attr(e, kAXSizeAttribute) else { return nil }
        AXValueGetValue(pv as! AXValue, .cgPoint, &p); AXValueGetValue(sv as! AXValue, .cgSize, &s)
        return CGRect(origin: p, size: s)
    }

    /// Chrome/Edge/Arc only build their accessibility tree when asked; Safari always exposes it.
    /// Apps like Figma have several web views (a thin tab bar, side panels, the canvas), so the largest one is the page area.
    /// The search does not descend into a web view's own content, which keeps it fast.
    private static func findWebArea(in root: AXUIElement) -> AXUIElement? {
        var queue = [root], seen = 0
        var best: (element: AXUIElement, area: CGFloat)?
        while !queue.isEmpty, seen < 2500 {
            let e = queue.removeFirst(); seen += 1
            if attr(e, kAXRoleAttribute) as? String == "AXWebArea" {
                if let f = frame(e), best == nil || f.width * f.height > best!.area { best = (e, f.width * f.height) }
                continue
            }
            queue.append(contentsOf: (attr(e, kAXChildrenAttribute) as? [AXUIElement]) ?? [])
        }
        return best?.element
    }

    /// Live margins between the window edge and the page area (top, right, bottom, left). Needs Accessibility; nil if the app has no web area.
    static func measureViewport(of app: NSRunningApplication) -> (top: Double, right: Double, bottom: Double, left: Double)? {
        guard AXIsProcessTrusted() else { return nil }
        let ax = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetAttributeValue(ax, "AXManualAccessibility" as CFString, kCFBooleanTrue)
        guard let win = attr(ax, kAXFocusedWindowAttribute) ?? attr(ax, kAXMainWindowAttribute),
              let wf = frame(win as! AXUIElement),
              let web = findWebArea(in: win as! AXUIElement), let f = frame(web), f.width > 0, f.height > 0 else { return nil }
        return (f.minY - wf.minY, wf.maxX - f.maxX, wf.maxY - f.maxY, f.minX - wf.minX)
    }

    /// Window corner radius in points, read from the transparent corners of a shadowless window screenshot.
    static func measureCornerRadius(of app: NSRunningApplication) -> Double? {
        guard let info = windowInfo(of: app) else { return nil }
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("fc-corner-\(UUID().uuidString).png")
        defer { try? FileManager.default.removeItem(at: tmp) }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        p.arguments = ["-x", "-o", "-l", String(info.id), tmp.path]
        try? p.run(); p.waitUntilExit()
        guard let data = try? Data(contentsOf: tmp), let cg = NSBitmapImageRep(data: data)?.cgImage else { return nil }

        let w = cg.width, h = cg.height
        var buf = [UInt8](repeating: 0, count: w * h * 4)
        let ok: Bool = buf.withUnsafeMutableBytes { raw in
            guard let ctx = CGContext(data: raw.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                      space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        guard ok else { return nil }
        // On a circle of radius r the corner's diagonal turns opaque at d = r(1 - 1/√2) ≈ 0.2929 r (memory row 0 is the top row).
        var d = 0
        while d < min(w, h) / 2, buf[(d * w + d) * 4 + 3] < 128 { d += 1 }
        let scale = Double(w) / Double(info.bounds.width)
        let r = Double(d) / 0.2929 / scale
        return r < 100 ? r : nil
    }

    /// Sets the window so its *content area* (outer size minus margins) equals the preset, then reads the result back
    /// and logs it. Returns false only if the window couldn't be resized at all.
    static func resize(app: NSRunningApplication, to preset: SizePreset) -> Bool {
        guard ensureAccessibility(), let id = app.bundleIdentifier else { NSLog("FlowCapture: resize needs Accessibility permission"); return false }
        let axApp = AXUIElementCreateApplication(app.processIdentifier)
        guard let win = attr(axApp, kAXFocusedWindowAttribute) else { NSLog("FlowCapture: resize: no focused window"); return false }
        let w = win as! AXUIElement

        func margins() -> Margins { effectiveMargins(for: app) }
        func setOuter(_ m: Margins) -> Bool {
            var size = CGSize(width: preset.width + m.left + m.right, height: preset.height + m.top + m.bottom)
            guard let value = AXValueCreate(.cgSize, &size) else { return false }
            return AXUIElementSetAttributeValue(w, kAXSizeAttribute as CFString, value) == .success
        }

        UserDefaults.standard.set([preset.width, preset.height], forKey: "preset.\(id)")
        guard setOuter(margins()) else { NSLog("FlowCapture: resize: setting size failed for \(id)"); return false }
        // Second pass: margins can change once the window is resized (e.g. toolbar reflow); correct any drift.
        _ = setOuter(margins())

        if let f = measureViewport(of: app), let wf = frame(w) {
            let page = CGSize(width: wf.width - f.left - f.right, height: wf.height - f.top - f.bottom)
            let ok = abs(page.width - preset.width) < 1.5 && abs(page.height - preset.height) < 1.5
            NSLog("FlowCapture: resize \(preset.name): page area is \(Int(page.width))×\(Int(page.height))\(ok ? "" : " — the app refused the full size (minimum window size?)")")
        } else {
            NSLog("FlowCapture: resize \(preset.name): applied, but couldn't read the page area back")
        }
        return true
    }
}
