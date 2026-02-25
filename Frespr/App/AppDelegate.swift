import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let menuBar = MenuBarController()
    private let coordinator = GeminiSessionCoordinator()
    private let overlayViewModel = OverlayViewModel()
    private var overlayWindow: OverlayWindow?
    private var hotKeyMonitor: GlobalHotKeyMonitor?
    private var escapeMonitor: Any?
    private var settingsWC: SettingsWindowController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)

        // 1. Menu bar
        menuBar.setup()
        menuBar.onSettings = { [weak self] in self?.openSettings() }
        menuBar.onQuit = { NSApplication.shared.terminate(nil) }
        menuBar.onReinject = { text in TextInjector.shared.inject(text: text) }

        // 2. Overlay window (created but hidden)
        overlayWindow = OverlayWindow(viewModel: overlayViewModel)

        // 3. Coordinator callbacks
        coordinator.onStateChange = { [weak self] state in self?.handleStateChange(state) }
        coordinator.onTranscriptUpdate = { [weak self] text, isFinal in self?.handleTranscriptUpdate(text: text, isFinal: isFinal) }
        coordinator.onError = { [weak self] msg in self?.showErrorToast(msg) }

        // 4. Hotkey
        let monitor = GlobalHotKeyMonitor()
        monitor.option = AppSettings.shared.hotKeyOption
        monitor.onKeyDown = { Task { @MainActor [weak self] in self?.coordinator.handleHotkeyPress() } }
        monitor.onPermissionNeeded = { Task { @MainActor [weak self] in self?.handleAccessibilityPermissionNeeded() } }
        monitor.start()
        hotKeyMonitor = monitor

        NotificationCenter.default.addObserver(
            forName: .hotKeyChanged,
            object: nil,
            queue: nil
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.hotKeyMonitor?.option = AppSettings.shared.hotKeyOption
                self.hotKeyMonitor?.restart()
            }
        }

        // 5. Global Escape key to cancel recording
        installEscapeMonitor()

        // 6. Permissions
        Task { await PermissionManager.shared.checkAndRequestAll() }

        // 7. Open Settings on first launch if no API key
        if AppSettings.shared.geminiAPIKey.isEmpty {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
                self?.openSettings()
            }
        }
    }

    // MARK: - State Handling

    private func handleStateChange(_ state: GeminiSessionCoordinator.SessionState) {
        switch state {
        case .idle:
            menuBar.setIcon(.idle)
            overlayWindow?.hideIfIdle()
            if !(overlayWindow?.hasPendingHide ?? false) {
                overlayViewModel.reset()
            }
        case .connecting:
            menuBar.setIcon(.recording)
            overlayViewModel.state = .recording
            overlayViewModel.interimText = ""
            overlayWindow?.show()
        case .recording:
            menuBar.setIcon(.recording)
            overlayViewModel.state = .recording
            overlayWindow?.show()
        case .processing:
            menuBar.setIcon(.processing)
            overlayViewModel.state = .processing
        case .error(let msg):
            menuBar.setIcon(.idle)
            showErrorToast(msg)
        }
    }

    private func handleTranscriptUpdate(text: String, isFinal: Bool) {
        if isFinal {
            overlayViewModel.finalText = text
            overlayViewModel.interimText = ""
            // Flash success, then hide. The coordinator will inject text after cleanup.
            overlayWindow?.flashInjected()
        } else {
            overlayViewModel.interimText = text
        }
    }

    // MARK: - Escape to cancel

    private func installEscapeMonitor() {
        escapeMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard event.keyCode == 53 else { return }  // 53 = Escape
            Task { @MainActor [weak self] in
                self?.coordinator.cancelRecording()
            }
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

    // MARK: - Accessibility Permission

    private func handleAccessibilityPermissionNeeded() {
        showErrorToast("Frespr needs Accessibility access to detect the hotkey. Please grant it in System Settings → Privacy → Accessibility, then relaunch.")
        PermissionManager.shared.requestAccessibilityAccess()
    }

    // MARK: - Error Toast

    private func showErrorToast(_ message: String) {
        menuBar.setIcon(.idle)
        overlayWindow?.showError(message)
    }
}
