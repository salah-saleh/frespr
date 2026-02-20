import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let menuBar = MenuBarController()
    private let coordinator = GeminiSessionCoordinator()
    private let overlayViewModel = OverlayViewModel()
    private var overlayWindow: OverlayWindow?
    private var hotKeyMonitor: GlobalHotKeyMonitor?
    private var settingsWC: SettingsWindowController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)

        // 1. Menu bar
        menuBar.setup()
        menuBar.onSettings = { [weak self] in self?.openSettings() }
        menuBar.onQuit = { NSApplication.shared.terminate(nil) }

        // 2. Overlay window (created but hidden)
        overlayWindow = OverlayWindow(viewModel: overlayViewModel)

        // 3. Coordinator callbacks
        coordinator.onStateChange = { [weak self] state in self?.handleStateChange(state) }
        coordinator.onTranscriptUpdate = { [weak self] text, isFinal in self?.handleTranscriptUpdate(text: text, isFinal: isFinal) }
        coordinator.onError = { [weak self] msg in self?.showError(msg) }

        // 4. Hotkey
        let monitor = GlobalHotKeyMonitor()
        monitor.onKeyDown = { Task { @MainActor [weak self] in self?.coordinator.handleHotkeyPress() } }
        monitor.onKeyUp   = { Task { @MainActor [weak self] in self?.coordinator.handleHotkeyRelease() } }
        monitor.start(mode: AppSettings.shared.hotkeyMode)
        hotKeyMonitor = monitor

        // 5. Permissions
        Task { await PermissionManager.shared.checkAndRequestAll() }

        // 6. Open Settings on first launch if no API key
        if AppSettings.shared.geminiAPIKey.isEmpty {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
                self?.openSettings()
            }
        }
    }

    // MARK: - State Handling

    private func handleStateChange(_ state: GeminiSessionCoordinator.SessionState) {
        let settings = AppSettings.shared
        switch state {
        case .idle:
            menuBar.setIcon(.idle)
            overlayViewModel.reset()
            // Hide immediately so focus returns to target app before text injection runs
            if settings.showOverlay { overlayWindow?.hide() }
        case .connecting:
            menuBar.setIcon(.recording)
            overlayViewModel.state = .recording
            overlayViewModel.interimText = ""
            if settings.showOverlay { overlayWindow?.show() }
        case .recording:
            menuBar.setIcon(.recording)
            overlayViewModel.state = .recording
            if settings.showOverlay { overlayWindow?.show() }
        case .processing:
            menuBar.setIcon(.processing)
            overlayViewModel.state = .processing
        case .error(let msg):
            menuBar.setIcon(.idle)
            overlayWindow?.hide()
            showError(msg)
        }
    }

    private func handleTranscriptUpdate(text: String, isFinal: Bool) {
        if isFinal {
            overlayViewModel.finalText = text
            overlayViewModel.interimText = ""
        } else {
            overlayViewModel.interimText = text
        }
    }

    // MARK: - Settings

    private func openSettings() {
        if let existing = settingsWC {
            existing.showSettings()
            return
        }
        let wc = SettingsWindowController()
        wc.window?.center()
        wc.onClose = { [weak self] in self?.settingsWC = nil }
        settingsWC = wc
        wc.showSettings()
    }

    // MARK: - Error

    private func showError(_ message: String) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "Frespr Error"
        alert.informativeText = message
        alert.alertStyle = .warning
        alert.addButton(withTitle: "OK")
        alert.runModal()
        NSApp.setActivationPolicy(.accessory)
    }
}
