import AppKit

final class MenuBarController: NSObject, NSMenuDelegate {
    private var statusItem: NSStatusItem?

    var onSettings: (() -> Void)?
    var onQuit: (() -> Void)?
    var onReinject: ((String) -> Void)?

    func setup() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem = item

        guard let button = item.button else { return }
        button.image = Self.menuBarImage(named: "menubar") ?? NSImage(systemSymbolName: "mic", accessibilityDescription: "Frespr")
        button.image?.isTemplate = true

        let menu = NSMenu()
        menu.delegate = self

        let ppItem = NSMenuItem(title: "Post-processing", action: nil, keyEquivalent: "")
        ppItem.submenu = buildPostProcessingMenu()
        menu.addItem(ppItem)

        let historyItem = NSMenuItem(title: "History", action: nil, keyEquivalent: "")
        historyItem.submenu = NSMenu()
        menu.addItem(historyItem)

        menu.addItem(.separator())

        let settingsItem = NSMenuItem(title: "Settings…", action: #selector(openSettings), keyEquivalent: ",")
        settingsItem.target = self
        menu.addItem(settingsItem)

        menu.addItem(.separator())

        let quitItem = NSMenuItem(title: "Quit Frespr", action: #selector(quit), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)

        item.menu = menu
    }

    func menuWillOpen(_ menu: NSMenu) {
        if let ppItem = menu.item(withTitle: "Post-processing") {
            ppItem.submenu = buildPostProcessingMenu()
        }
        if let histItem = menu.item(withTitle: "History") {
            histItem.submenu = buildHistoryMenu()
        }
    }

    private func buildPostProcessingMenu() -> NSMenu {
        let sub = NSMenu()
        let current = AppSettings.shared.postProcessingMode
        for (i, mode) in PostProcessingMode.allCases.enumerated() {
            let item = NSMenuItem(title: mode.displayName, action: #selector(setMode(_:)), keyEquivalent: "")
            item.target = self
            item.tag = i
            item.state = mode == current ? .on : .off
            sub.addItem(item)
        }
        return sub
    }

    func setIcon(_ icon: MenuBarIcon) {
        let name: String
        switch icon {
        case .idle:       name = "menubar"
        case .recording:  name = "menubar-recording"
        case .processing: name = "menubar-processing"
        }
        statusItem?.button?.image = Self.menuBarImage(named: name)
        statusItem?.button?.image?.isTemplate = true
    }

    // Load the @2x-aware menu bar PNG from the app bundle
    private static func menuBarImage(named name: String) -> NSImage? {
        guard let url = Bundle.main.url(forResource: name, withExtension: "png") else { return nil }
        guard let img = NSImage(contentsOf: url) else { return nil }
        img.size = NSSize(width: 18, height: 18)
        img.isTemplate = true
        return img
    }

    private func buildHistoryMenu() -> NSMenu {
        let sub = NSMenu()
        let entries = TranscriptionLog.shared.entries.reversed()
        if entries.isEmpty {
            let empty = NSMenuItem(title: "(No history)", action: nil, keyEquivalent: "")
            empty.isEnabled = false
            sub.addItem(empty)
        } else {
            for (i, entry) in entries.enumerated() {
                let preview = String(entry.text.prefix(55))
                    .replacingOccurrences(of: "\n", with: " ")
                let suffix = entry.text.count > 55 ? "…" : ""
                let title = "\(Self.relativeTime(entry.timestamp))  \(preview)\(suffix)"
                let item = NSMenuItem(title: title,
                                      action: #selector(reinjectHistory(_:)),
                                      keyEquivalent: "")
                item.target = self
                item.tag = i
                sub.addItem(item)
            }
            sub.addItem(.separator())
            let clear = NSMenuItem(title: "Clear History",
                                   action: #selector(clearHistory),
                                   keyEquivalent: "")
            clear.target = self
            sub.addItem(clear)
        }
        return sub
    }

    private static func relativeTime(_ date: Date) -> String {
        let sec = Int(-date.timeIntervalSinceNow)
        if sec < 60   { return "Just now" }
        if sec < 3600 { return "\(sec / 60)m ago" }
        if sec < 86400 { return "\(sec / 3600)h ago" }
        return "\(sec / 86400)d ago"
    }

    @objc private func reinjectHistory(_ sender: NSMenuItem) {
        let entries = Array(TranscriptionLog.shared.entries.reversed())
        guard sender.tag < entries.count else { return }
        onReinject?(entries[sender.tag].text)
    }

    @objc private func clearHistory() {
        TranscriptionLog.shared.clear()
    }

    @objc private func setMode(_ sender: NSMenuItem) {
        let modes = PostProcessingMode.allCases
        guard sender.tag < modes.count else { return }
        AppSettings.shared.postProcessingMode = modes[sender.tag]
    }

    @objc private func openSettings() { onSettings?() }
    @objc private func quit()         { onQuit?() }
}

enum MenuBarIcon { case idle, recording, processing }
