import AppKit

final class MenuBarController: NSObject, NSMenuDelegate {
    private var statusItem: NSStatusItem?

    var onSettings: (() -> Void)?
    var onQuit: (() -> Void)?

    func setup() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem = item

        guard let button = item.button else { return }
        button.image = NSImage(systemSymbolName: "mic", accessibilityDescription: "Frespr")
        button.image?.isTemplate = true

        let menu = NSMenu()
        menu.delegate = self

        let ppItem = NSMenuItem(title: "Post-processing", action: nil, keyEquivalent: "")
        ppItem.submenu = buildPostProcessingMenu()
        menu.addItem(ppItem)

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
        case .idle:       name = "mic"
        case .recording:  name = "mic.fill"
        case .processing: name = "waveform"
        }
        statusItem?.button?.image = NSImage(systemSymbolName: name, accessibilityDescription: "Frespr")
        statusItem?.button?.image?.isTemplate = true
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
