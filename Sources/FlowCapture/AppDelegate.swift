import AppKit
import Carbon

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var finishItem: NSMenuItem!
    private var previewItem: NSMenuItem!
    private var undoItem: NSMenuItem!
    private var discardItem: NSMenuItem!
    private var windowItem: NSMenuItem!
    private var selectionItem: NSMenuItem!
    private var warnedAboutStorage = false
    private static let storageWarningBytes = 50 * 1_000_000
    private var statusItem: NSStatusItem!
    private let server = Server()
    private var settings: SettingsWindowController!
    /// Last frontmost app other than us; menu clicks and note dialogs would otherwise make *us* frontmost.
    private var target: NSRunningApplication?

    /// When launched from the .app, settings live under the bundle identifier instead of the old terminal-run name
    /// ("FlowCapture"). Copy them across once so shortcuts, trims and the FigJam token survive the move.
    private func migrateLegacyDefaults() {
        let done = "migratedLegacyDefaults", d = UserDefaults.standard
        guard Bundle.main.bundleIdentifier != nil, !d.bool(forKey: done) else { return }
        if d.string(forKey: "serverToken") == nil, let legacy = d.persistentDomain(forName: "FlowCapture") {
            for (k, v) in legacy { d.set(v, forKey: k) }
        }
        d.set(true, forKey: done)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        migrateLegacyDefaults()
        installEditMenu()
        DispatchQueue.main.async { [weak self] in self?.checkStorageWarning() }
        server.start()
        target = NSWorkspace.shared.frontmostApplication
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] n in
            if let a = n.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
               a.bundleIdentifier != Bundle.main.bundleIdentifier, a.processIdentifier != getpid() {
                self?.target = a
            }
        }

        settings = SettingsWindowController(hooks: .init(
            shortcutsChanged: { [weak self] in self?.registerHotkeys() ?? [] },
            recording: { [weak self] on in if on { HotKey.unregisterAll() } else { _ = self?.registerHotkeys() } },
            copyToken: { [weak self] in self?.copyToken() },
            clearSent: { [weak self] in self?.clearSent() },
            openFolder: { [weak self] in self?.openFolder() },
            storageText: { "\(AppDelegate.mb(Store.shared.totalBytes())) used  ·  \(Store.shared.sentStats().count) already sent to FigJam" }
        ))

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.image = NSImage(systemSymbolName: "camera.viewfinder", accessibilityDescription: "Flow Capture")
        buildMenu()
        _ = registerHotkeys()
        flowChanged()   // restores the step count and corner thumbnail of a flow that was in progress at quit
    }

    // MARK: Shortcuts

    /// (Re)registers every global shortcut. Returns the actions whose keys could not be registered.
    @discardableResult
    private func registerHotkeys() -> [ShortcutAction] {
        HotKey.unregisterAll()
        var failed: [ShortcutAction] = []
        for a in ShortcutAction.allCases {
            let s = Prefs.shortcut(a)
            if !HotKey.register(id: a.id, keyCode: s.keyCode, modifiers: s.modifiers, handler: { [weak self] in self?.run(a) }) { failed.append(a) }
        }
        applyShortcutsToMenu()
        return failed
    }

    private func run(_ a: ShortcutAction) {
        guard !Overlay.isActive else { return }   // dialogs and previews would open behind the capture overlay
        switch a {
        case .captureWindow: captureWindow()
        case .captureSelection: captureSelection()
        case .finishFlow: finishFlow()
        case .previewFlow: previewFlow()
        case .removeLastStep: removeLastStep()
        }
    }

    private func menuItem(for a: ShortcutAction) -> NSMenuItem {
        switch a {
        case .captureWindow: return windowItem
        case .captureSelection: return selectionItem
        case .finishFlow: return finishItem
        case .previewFlow: return previewItem
        case .removeLastStep: return undoItem
        }
    }

    /// Shows each shortcut at the right of its menu item. Keys that can't be a menu key equivalent go in the title instead.
    private func applyShortcutsToMenu() {
        guard windowItem != nil else { return }
        for a in ShortcutAction.allCases {
            let it = menuItem(for: a), s = Prefs.shortcut(a)
            if s.isPrintable { it.keyEquivalent = s.key; it.keyEquivalentModifierMask = s.nsModifiers }
            else { it.keyEquivalent = "" }
        }
        refreshFlowUI()
    }

    /// Accessory apps have no main menu, so ⌘C/⌘V/⌘X/⌘A/⌘Z do nothing in text fields. A hidden Edit menu restores them.
    private func installEditMenu() {
        let main = NSMenu()
        let editItem = NSMenuItem(); main.addItem(editItem)
        let edit = NSMenu(title: "Edit")
        func add(_ title: String, _ action: Selector, _ key: String, shift: Bool = false) {
            let it = NSMenuItem(title: title, action: action, keyEquivalent: key)
            if shift { it.keyEquivalentModifierMask = [.command, .shift] }
            edit.addItem(it)
        }
        add("Undo", Selector(("undo:")), "z"); add("Redo", Selector(("redo:")), "z", shift: true)
        edit.addItem(.separator())
        add("Cut", #selector(NSText.cut(_:)), "x"); add("Copy", #selector(NSText.copy(_:)), "c")
        add("Paste", #selector(NSText.paste(_:)), "v"); add("Select All", #selector(NSText.selectAll(_:)), "a")
        editItem.submenu = edit
        NSApp.mainMenu = main
    }

    private func buildMenu() {
        let menu = NSMenu()
        windowItem = item("Capture Window Content", #selector(captureWindow))
        selectionItem = item("Capture Selection", #selector(captureSelection))
        previewItem = item("Preview Flow", #selector(previewFlow))
        finishItem = item("Finish Flow → FigJam", #selector(finishFlow))
        undoItem = item("Remove Last Step", #selector(removeLastStep))
        discardItem = item("Discard Current Flow…", #selector(discardFlow))
        [windowItem, selectionItem].forEach(menu.addItem)
        menu.addItem(.separator())
        [previewItem, finishItem, undoItem, discardItem].forEach(menu.addItem)
        menu.addItem(.separator())

        let browser = NSMenu()
        let resize = NSMenu()
        for (i, p) in WindowTools.presets.enumerated() {
            let it = item(p.name, #selector(resizeWindow(_:))); it.tag = i; resize.addItem(it)
        }
        let resizeItem = NSMenuItem(title: "Resize Window To", action: nil, keyEquivalent: ""); resizeItem.submenu = resize
        browser.addItem(resizeItem)
        browser.addItem(item("Open URL in Clean Window…", #selector(openCleanWindow)))
        let browserItem = NSMenuItem(title: "Browser", action: nil, keyEquivalent: ""); browserItem.submenu = browser
        menu.addItem(browserItem)
        menu.addItem(.separator())

        let prefs = item("Settings…", #selector(openSettings)); prefs.keyEquivalent = ","
        menu.addItem(prefs)
        menu.addItem(.separator())

        let quit = NSMenuItem(title: "Quit Flow Capture", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        quit.target = NSApp   // the delegate does not implement terminate:, so targeting it left the item disabled
        menu.addItem(quit)
        menu.delegate = self
        statusItem.menu = menu
    }

    @objc private func openSettings() { settings.show() }

    func menuNeedsUpdate(_ menu: NSMenu) { refreshFlowUI() }

    private static func mb(_ bytes: Int) -> String { String(format: "%.0f MB", Double(bytes) / 1_000_000) }

    /// Deletes captures that already reached FigJam, after confirming. Unsent captures stay.
    @objc private func clearSent() {
        let sent = Store.shared.sentStats()
        guard sent.count > 0 else { return NSSound.beep() }
        let alert = NSAlert()
        alert.messageText = "Clear \(sent.count) sent capture\(sent.count == 1 ? "" : "s")?"
        alert.informativeText = "Frees \(AppDelegate.mb(sent.bytes)). These are already in FigJam. Captures not yet sent are kept."
        alert.addButton(withTitle: "Clear"); alert.addButton(withTitle: "Cancel")
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        Store.shared.clearSent()
    }

    /// One heads-up per session once captures pass 50 MB, if there is something safe to clear.
    private func checkStorageWarning() {
        guard !warnedAboutStorage, Store.shared.totalBytes() > AppDelegate.storageWarningBytes, Store.shared.sentStats().count > 0 else { return }
        warnedAboutStorage = true
        let alert = NSAlert()
        alert.messageText = "Captures are using \(AppDelegate.mb(Store.shared.totalBytes()))"
        alert.informativeText = "Clear the ones already sent to FigJam to free space (\(AppDelegate.mb(Store.shared.sentStats().bytes)))."
        alert.addButton(withTitle: "Clear Sent Captures"); alert.addButton(withTitle: "Later")
        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertFirstButtonReturn { Store.shared.clearSent() }
    }

    /// Shows the number of steps recorded so far next to the icon, and in the menu items that depend on it.
    func refreshFlowUI() {
        let n = Store.shared.openFlowCount()
        statusItem.button?.title = n > 0 ? " \(n)" : ""
        finishItem.title = "Finish Flow → FigJam" + (n > 0 ? "  (\(n) step\(n == 1 ? "" : "s"))" : "")
        finishItem.isEnabled = n > 0
        previewItem.isEnabled = n > 0
        undoItem.isEnabled = n > 0
        discardItem.isEnabled = n > 0
        // Keys that can't be a menu key equivalent (F-keys, arrows) are shown in the title instead.
        for a in [ShortcutAction.captureWindow, .captureSelection] {
            let it = menuItem(for: a), sc = Prefs.shortcut(a)
            it.title = a.title + (sc.isPrintable ? "" : "   " + sc.display)
        }
        for a in [ShortcutAction.finishFlow, .previewFlow, .removeLastStep] where !Prefs.shortcut(a).isPrintable {
            menuItem(for: a).title += "   " + Prefs.shortcut(a).display
        }
    }

    @objc private func previewFlow() { PreviewHUD.shared.openPreview() }

    /// Undo for the last capture.
    @objc private func removeLastStep() {
        if Store.shared.removeLastStep() { NSSound(named: "Pop")?.play(); flowChanged() } else { NSSound.beep() }
    }

    /// Throws away the whole flow that is being recorded, after confirming.
    @objc private func discardFlow() {
        let n = Store.shared.openFlowCount()
        guard n > 0 else { return NSSound.beep() }
        let alert = NSAlert()
        alert.messageText = "Discard this flow?"
        alert.informativeText = "This deletes the \(n) step\(n == 1 ? "" : "s") captured so far. It can't be undone."
        alert.addButton(withTitle: "Discard"); alert.addButton(withTitle: "Cancel")
        alert.buttons.first?.hasDestructiveAction = true
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        Store.shared.discardOpenFlow()
        flowChanged()
    }

    @objc private func finishFlow() {
        let n = Store.shared.openFlowCount()
        guard n > 0 else { return NSSound.beep() }

        let stamp = DateFormatter(); stamp.dateFormat = "MMM d, HH:mm"
        // A single screenshot needs no name: save it straight away under a dated default.
        if n == 1 {
            Store.shared.finishFlow(name: "Screenshot – \(stamp.string(from: Date()))")
            NSSound(named: "Glass")?.play()
            flowChanged()
            return
        }

        let alert = NSAlert()
        alert.messageText = "Finish this flow (\(n) step\(n == 1 ? "" : "s"))?"
        alert.informativeText = "Name it, then place it in FigJam whenever you're ready. You can start another flow right away."
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 300, height: 24))
        field.stringValue = "Flow – \(stamp.string(from: Date()))"
        alert.accessoryView = field
        alert.window.initialFirstResponder = field
        alert.addButton(withTitle: "Finish"); alert.addButton(withTitle: "Cancel")
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        let name = field.stringValue.trimmingCharacters(in: .whitespaces)
        Store.shared.finishFlow(name: name.isEmpty ? "Flow" : name)
        NSSound(named: "Glass")?.play()
        flowChanged()
    }

    private func flowChanged() { refreshFlowUI(); PreviewHUD.shared.refresh(); checkStorageWarning() }

    private func item(_ title: String, _ action: Selector) -> NSMenuItem {
        let it = NSMenuItem(title: title, action: action, keyEquivalent: ""); it.target = self; return it
    }

    // MARK: Capture

    /// Primary capture: the frontmost window's page area, with browser chrome trimmed. Trim and corners are adjusted inside the overlay.
    @objc private func captureWindow() {
        // At hotkey time we are still an accessory app, so the frontmost app is the one the user is looking at.
        var app = NSWorkspace.shared.frontmostApplication
        if app?.processIdentifier == getpid() { app = target }
        guard let app else { return fail("no frontmost app") }
        guard let id = app.bundleIdentifier else { return fail("\(app.localizedName ?? "app") has no bundle id") }
        guard let b = WindowTools.windowBounds(of: app) else { return fail("no visible window found for \(id)") }
        let eff = WindowTools.effective(for: app)
        let m = eff.margins
        let r = CGRect(x: b.minX + m.left, y: b.minY + m.top, width: b.width - m.left - m.right, height: b.height - m.top - m.bottom)
        guard r.width > 0, r.height > 0 else { return fail("margins \(m) leave no content area in \(b)") }
        NSLog("FlowCapture: window capture \(id) bounds=\(b) content=\(r) clean=\(eff.isClean)")

        var ctx = CaptureContext(mode: .window, contentRect: r, windowRect: b, margins: m, radius: m.radius,
                                 rememberTitle: eff.isClean ? "Remember for clean windows" : "Remember trim for \(app.localizedName ?? id)",
                                 remember: true, expected: WindowTools.lastPreset(bundleID: id))
        if eff.isClean {
            ctx.quickTitle = "Reset"; ctx.quick = { Margins.cleanWindowDefault }
        } else if eff.canAuto {
            ctx.quickTitle = "Auto"; ctx.quickIsAuto = true
            ctx.quick = {
                guard let v = WindowTools.measureViewport(of: app) else { return nil }
                return Margins(top: v.top, right: v.right, bottom: v.bottom, left: v.left, radius: WindowTools.measureCornerRadius(of: app) ?? m.radius)
            }
        } else if let preset = Margins.builtIn[id] {
            ctx.quickTitle = "Reset"; ctx.quick = { preset }
        }
        Overlay.begin(ctx, persist: { [weak self] in self?.persistWindow($0, bundleID: id, isClean: eff.isClean) }) { [weak self] in self?.flowChanged() }
    }

    /// Secondary capture: a drag-selected area. Reopens on the previous area (resizable) unless "remember" is off.
    @objc private func captureSelection() {
        var ctx = CaptureContext(mode: .selection, radius: Prefs.selectionRadius, rememberTitle: "Remember this area", remember: Prefs.rememberSelection)
        if Prefs.rememberSelection { ctx.contentRect = Prefs.lastSelection }
        Overlay.begin(ctx, persist: { r in
            if Prefs.rememberSelection { Prefs.lastSelection = r.globalRect }
            if r.outcome.radiusEdited { Prefs.selectionRadius = Double(r.outcome.radius) }
        }) { [weak self] in self?.flowChanged() }
    }

    /// Saves what the user adjusted in the overlay so the next capture of this app starts from it.
    private func persistWindow(_ r: CaptureResult, bundleID: String, isClean: Bool) {
        let o = r.outcome
        NSLog("FlowCapture: remember trim? remember=\(o.remember) edited=\(o.trimEdited) radiusEdited=\(o.radiusEdited) auto=\(o.usedAuto) reset=\(o.usedReset) clean=\(isClean) trim=\(String(describing: o.trim)) radius=\(o.radius) app=\(bundleID)")
        guard o.remember, let trim = o.trim else { return }
        if isClean {
            var m = Margins.loadClean()
            if o.usedReset { m = Margins.cleanWindowDefault }
            else {
                if o.trimEdited { m.top = trim.top; m.right = trim.right; m.bottom = trim.bottom; m.left = trim.left }
                if o.radiusEdited { m.radius = Double(o.radius) }
            }
            m.saveClean()
        } else {
            var m = Margins.load(bundleID: bundleID)
            if o.radiusEdited || o.usedAuto { m.radius = Double(o.radius) }
            if o.usedAuto { m.pinned = false }
            else if o.trimEdited { m.top = trim.top; m.right = trim.right; m.bottom = trim.bottom; m.left = trim.left; m.pinned = true }
            m.save(bundleID: bundleID)
        }
    }

    private func fail(_ why: String) {
        NSLog("FlowCapture: window capture failed: \(why)")
        NSSound.beep()
    }

    // MARK: Clean browser window

    private static let browsers = [("Microsoft Edge", "com.microsoft.edgemac"), ("Google Chrome", "com.google.Chrome")]

    /// Opens a URL in a Chromium "app" window (no tabs/address bar) and snaps its page area to a preset size.
    @objc private func openCleanWindow() {
        let installed = AppDelegate.browsers.filter { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0.1) != nil }
        guard !installed.isEmpty else { return NSSound.beep() }
        let defaults = UserDefaults.standard

        let urlField = NSTextField(frame: NSRect(x: 0, y: 64, width: 340, height: 24))
        urlField.placeholderString = "https://example.com"
        urlField.stringValue = defaults.string(forKey: "cleanURL") ?? ""
        let presetPopup = NSPopUpButton(frame: NSRect(x: 0, y: 32, width: 340, height: 26))
        presetPopup.addItems(withTitles: WindowTools.presets.map(\.name))
        presetPopup.selectItem(at: min(defaults.integer(forKey: "cleanPreset"), WindowTools.presets.count - 1))
        let browserPopup = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 340, height: 26))
        browserPopup.addItems(withTitles: installed.map { $0.0 })
        if let i = installed.firstIndex(where: { $0.1 == defaults.string(forKey: "cleanBrowser") }) { browserPopup.selectItem(at: i) }
        let box = NSView(frame: NSRect(x: 0, y: 0, width: 340, height: 92))
        [urlField, presetPopup, browserPopup].forEach(box.addSubview)

        let alert = NSAlert()
        alert.messageText = "Open in a clean window"
        alert.informativeText = "No tabs or address bar, at an exact page size."
        alert.accessoryView = box
        alert.addButton(withTitle: "Open"); alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = urlField
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        var url = urlField.stringValue.trimmingCharacters(in: .whitespaces)
        guard !url.isEmpty else { return NSSound.beep() }
        if !url.contains("://") { url = "https://" + url }
        let preset = WindowTools.presets[presetPopup.indexOfSelectedItem]
        let browser = installed[browserPopup.indexOfSelectedItem]
        defaults.set(urlField.stringValue, forKey: "cleanURL")
        defaults.set(presetPopup.indexOfSelectedItem, forKey: "cleanPreset")
        defaults.set(browser.1, forKey: "cleanBrowser")

        // Running the browser's own executable hands the arguments to an already-running instance.
        guard let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: browser.1),
              let exe = Bundle(url: appURL)?.executableURL else { return NSSound.beep() }
        let p = Process()
        p.executableURL = exe
        p.arguments = ["--app=\(url)", "--window-size=\(Int(preset.width)),\(Int(preset.height))"]
        p.standardOutput = FileHandle.nullDevice; p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return NSSound.beep() }
        snapWhenReady(bundleID: browser.1, preset: preset, attemptsLeft: 5)
    }

    /// The new window takes a moment to appear; retry until the resize sticks.
    private func snapWhenReady(bundleID: String, preset: SizePreset, attemptsLeft: Int) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
            guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first else { return }
            if !WindowTools.resize(app: app, to: preset), attemptsLeft > 1 {
                self?.snapWhenReady(bundleID: bundleID, preset: preset, attemptsLeft: attemptsLeft - 1)
            }
        }
    }

    // MARK: Window tools

    @objc private func resizeWindow(_ sender: NSMenuItem) {
        guard let app = target, WindowTools.resize(app: app, to: WindowTools.presets[sender.tag]) else { return NSSound.beep() }
    }

    // MARK: Misc

    @objc private func copyToken() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(Server.token, forType: .string)
    }

    @objc private func openFolder() { NSWorkspace.shared.open(Store.shared.dir) }
}
