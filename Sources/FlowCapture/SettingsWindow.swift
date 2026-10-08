import AppKit
import ServiceManagement

/// Settings: shortcuts, selection memory, FigJam connection and storage.
final class SettingsWindowController {
    struct Hooks {
        var shortcutsChanged: () -> [ShortcutAction]      // re-registers hotkeys; returns the ones that could not be registered
        var recording: (Bool) -> Void                     // pause global hotkeys while a shortcut is being recorded
        var copyToken: () -> Void
        var showPluginFiles: () -> Void
        var clearSent: () -> Void
        var openFolder: () -> Void
        var storageText: () -> String
    }

    private let hooks: Hooks
    private var window: NSWindow?
    private var recorders: [ShortcutAction: ShortcutRecorder] = [:]
    private var storageLabel = NSTextField(labelWithString: "")

    init(hooks: Hooks) { self.hooks = hooks }

    func show() {
        if window == nil { build() }
        storageLabel.stringValue = hooks.storageText()
        recorders.values.forEach { $0.refresh() }
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func build() {
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 440, height: 10), styleMask: [.titled, .closable], backing: .buffered, defer: false)
        w.title = "Flow Capture Settings"
        w.isReleasedWhenClosed = false

        func header(_ t: String) -> NSTextField {
            let l = NSTextField(labelWithString: t); l.font = .systemFont(ofSize: 13, weight: .semibold); return l
        }
        func button(_ title: String, _ sel: Selector) -> NSButton {
            let b = NSButton(title: title, target: self, action: sel); b.bezelStyle = .rounded; return b
        }

        let stack = NSStackView()
        stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 10
        stack.edgeInsets = NSEdgeInsets(top: 20, left: 20, bottom: 20, right: 20)

        stack.addArrangedSubview(header("Shortcuts"))
        for a in ShortcutAction.allCases {
            let label = NSTextField(labelWithString: a.title); label.frame.size.width = 190
            label.widthAnchor.constraint(equalToConstant: 190).isActive = true
            let rec = ShortcutRecorder(action: a)
            rec.hooks = (recording: hooks.recording, changed: { [weak self] in self?.shortcutsChanged() })
            recorders[a] = rec
            let reset = button("Reset", #selector(resetShortcut(_:))); reset.identifier = NSUserInterfaceItemIdentifier(a.rawValue)
            let row = NSStackView(views: [label, rec, reset]); row.spacing = 8
            stack.addArrangedSubview(row)
        }
        let hint = NSTextField(wrappingLabelWithString: "Click a shortcut, then press the new keys. Two keys (a modifier plus one key) keeps it quick. Function keys work on their own.")
        hint.font = .systemFont(ofSize: 11); hint.textColor = .secondaryLabelColor
        hint.preferredMaxLayoutWidth = 400
        stack.addArrangedSubview(hint)

        stack.addArrangedSubview(NSBox.separator())
        stack.addArrangedSubview(header("General"))
        let login = NSButton(checkboxWithTitle: "Open Flow Capture at login", target: self, action: #selector(toggleLogin(_:)))
        let isApp = Bundle.main.bundleURL.pathExtension == "app"   // login items only work for a real app bundle
        login.isEnabled = isApp
        login.state = isApp && SMAppService.mainApp.status == .enabled ? .on : .off
        stack.addArrangedSubview(login)
        if !isApp {
            let note = NSTextField(wrappingLabelWithString: "Available when running as an app (see scripts/build-app.sh).")
            note.font = .systemFont(ofSize: 11); note.textColor = .secondaryLabelColor; note.preferredMaxLayoutWidth = 400
            stack.addArrangedSubview(note)
        }

        stack.addArrangedSubview(NSBox.separator())
        stack.addArrangedSubview(header("Capture Selection"))
        let remember = NSButton(checkboxWithTitle: "Remember the last selection area", target: self, action: #selector(toggleRemember(_:)))
        remember.state = Prefs.rememberSelection ? .on : .off
        stack.addArrangedSubview(remember)
        let rememberHint = NSTextField(wrappingLabelWithString: "On: the next capture opens on the same area, and you can still resize it. Off: you drag a new area every time.")
        rememberHint.font = .systemFont(ofSize: 11); rememberHint.textColor = .secondaryLabelColor; rememberHint.preferredMaxLayoutWidth = 400
        stack.addArrangedSubview(rememberHint)

        stack.addArrangedSubview(NSBox.separator())
        stack.addArrangedSubview(header("Capture overlay"))
        let sizeRow = NSStackView(); sizeRow.spacing = 8
        let seg = NSSegmentedControl(labels: ["Compact", "Regular", "Large"], trackingMode: .selectOne, target: self, action: #selector(sizeChanged(_:)))
        seg.selectedSegment = Prefs.uiScales.enumerated().min { abs($0.element - Prefs.uiScale) < abs($1.element - Prefs.uiScale) }?.offset ?? 0
        sizeRow.addArrangedSubview(NSTextField(labelWithString: "Toolbar size"))
        sizeRow.addArrangedSubview(seg)
        stack.addArrangedSubview(sizeRow)

        stack.addArrangedSubview(NSBox.separator())
        stack.addArrangedSubview(header("FigJam"))
        let figjamRow = NSStackView(views: [button("Copy Connection Token", #selector(copyToken)), button("Show Plugin Files", #selector(showPluginFiles))])
        figjamRow.spacing = 8
        stack.addArrangedSubview(figjamRow)

        stack.addArrangedSubview(NSBox.separator())
        stack.addArrangedSubview(header("Storage"))
        stack.addArrangedSubview(storageLabel)
        let storageRow = NSStackView(views: [button("Clear Sent Captures…", #selector(clearSent)), button("Open Captures Folder", #selector(openFolder))])
        storageRow.spacing = 8
        stack.addArrangedSubview(storageRow)

        w.contentView = stack
        w.setContentSize(stack.fittingSize)
        w.center()
        window = w
    }

    private func shortcutsChanged() {
        let failed = hooks.shortcutsChanged()
        recorders.values.forEach { $0.refresh() }
        guard !failed.isEmpty else { return }
        let alert = NSAlert()
        alert.messageText = "Some shortcuts could not be used"
        alert.informativeText = failed.map { "\($0.title): \(Prefs.shortcut($0).display)" }.joined(separator: "\n")
            + "\n\nAnother app is probably using them. Pick different keys."
        alert.beginSheetModal(for: window!)
    }

    @objc private func resetShortcut(_ sender: NSButton) {
        guard let raw = sender.identifier?.rawValue, let a = ShortcutAction(rawValue: raw) else { return }
        Prefs.setShortcut(nil, for: a)
        shortcutsChanged()
    }
    @objc private func sizeChanged(_ sender: NSSegmentedControl) { Prefs.uiScale = Prefs.uiScales[min(max(sender.selectedSegment, 0), Prefs.uiScales.count - 1)] }
    @objc private func toggleLogin(_ sender: NSButton) {
        do {
            if sender.state == .on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch {
            sender.state = sender.state == .on ? .off : .on   // revert; macOS refused
            NSLog("FlowCapture: could not change login item: \(error)")
        }
    }
    @objc private func toggleRemember(_ sender: NSButton) { Prefs.rememberSelection = sender.state == .on }
    @objc private func copyToken() { hooks.copyToken() }
    @objc private func showPluginFiles() { hooks.showPluginFiles() }
    @objc private func clearSent() { hooks.clearSent(); storageLabel.stringValue = hooks.storageText() }
    @objc private func openFolder() { hooks.openFolder() }
}

private extension NSBox {
    static func separator() -> NSBox {
        let b = NSBox(); b.boxType = .separator
        b.widthAnchor.constraint(equalToConstant: 400).isActive = true
        return b
    }
}

/// Button that records the next key combination.
private final class ShortcutRecorder: NSButton {
    let action_: ShortcutAction
    var hooks: (recording: (Bool) -> Void, changed: () -> Void)?
    private var monitor: Any?

    init(action: ShortcutAction) {
        action_ = action
        super.init(frame: NSRect(x: 0, y: 0, width: 130, height: 24))
        bezelStyle = .rounded
        target = self; self.action = #selector(begin)
        widthAnchor.constraint(equalToConstant: 130).isActive = true
        refresh()
    }
    required init?(coder: NSCoder) { fatalError() }

    func refresh() { title = Prefs.shortcut(action_).display }

    @objc private func begin() {
        guard monitor == nil else { return }
        title = "Press keys…"
        hooks?.recording(true)   // otherwise an existing global shortcut would fire instead of being recorded
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] e in
            // If the settings window was closed mid-recording, stop and let the key through.
            guard let self, self.window?.isVisible == true else { self?.end(changed: false); return e }
            self.handle(e); return nil
        }
    }

    private func handle(_ e: NSEvent) {
        if e.keyCode == 53 { return end(changed: false) }   // esc cancels
        guard let s = Shortcut.from(e) else { title = "Add a modifier key"; return }
        if let other = ShortcutAction.allCases.first(where: { $0 != action_ && Prefs.shortcut($0) == s }) {
            title = "Used by \(other.title)"; return
        }
        Prefs.setShortcut(s, for: action_)
        end(changed: true)
    }

    private func end(changed: Bool) {
        if let m = monitor { NSEvent.removeMonitor(m); monitor = nil }
        refresh()
        hooks?.recording(false)
        if changed { hooks?.changed() }
    }
}
