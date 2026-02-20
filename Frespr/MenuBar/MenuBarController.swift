import AppKit

final class MenuBarController {
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

        let settingsItem = NSMenuItem(title: "Settings…", action: #selector(openSettings), keyEquivalent: ",")
        settingsItem.target = self
        menu.addItem(settingsItem)

        menu.addItem(.separator())

        let quitItem = NSMenuItem(title: "Quit Frespr", action: #selector(quit), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)

        item.menu = menu
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

    @objc private func openSettings() { onSettings?() }
    @objc private func quit()         { onQuit?() }
}

enum MenuBarIcon { case idle, recording, processing }
