import AppKit

final class SettingsWindowController: NSWindowController, NSWindowDelegate {

    var onClose: (() -> Void)?

    private let apiKeyField    = NSTextField()
    private let apiKeyStatus   = NSImageView()
    private let holdRadio      = NSButton(radioButtonWithTitle: "Hold Right Option ⌥ — push to talk",        target: nil, action: nil)
    private let toggleRadio    = NSButton(radioButtonWithTitle: "Toggle Right Option ⌥ — tap to start/stop", target: nil, action: nil)
    private let overlayToggle  = NSButton(checkboxWithTitle: "Show overlay while recording", target: nil, action: nil)
    private let ppNoneRadio      = NSButton(radioButtonWithTitle: PostProcessingMode.none.displayName,      target: nil, action: nil)
    private let ppCleanupRadio   = NSButton(radioButtonWithTitle: PostProcessingMode.cleanup.displayName,   target: nil, action: nil)
    private let ppSummarizeRadio = NSButton(radioButtonWithTitle: PostProcessingMode.summarize.displayName, target: nil, action: nil)
    private let ppCustomRadio    = NSButton(radioButtonWithTitle: PostProcessingMode.custom.displayName,    target: nil, action: nil)
    private let ppCustomField    = NSTextField()
    private let micRow           = PermissionRowView(label: "Microphone")
    private let axRow            = PermissionRowView(label: "Accessibility (text injection)")

    convenience init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 440, height: 640),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "Frespr Settings"
        window.isReleasedWhenClosed = false
        self.init(window: window)
        window.delegate = self
        buildUI()
        loadValues()
    }

    // MARK: - Build UI

    private func buildUI() {
        guard let content = window?.contentView else { return }

        // Wrap everything in a stack view — easiest way to get correct
        // sizing without fighting the content view's autoresizing mask.
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 0
        stack.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(stack)

        // Pin stack to all four edges of the content view
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: content.topAnchor),
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: content.bottomAnchor),
        ])

        let p: CGFloat = 20

        // Helper: padded row
        func row(_ view: NSView, top: CGFloat = 0) -> NSView {
            let container = NSView()
            container.translatesAutoresizingMaskIntoConstraints = false
            view.translatesAutoresizingMaskIntoConstraints = false
            container.addSubview(view)
            NSLayoutConstraint.activate([
                view.topAnchor.constraint(equalTo: container.topAnchor, constant: top),
                view.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -8),
                view.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: p),
                view.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -p),
            ])
            return container
        }

        // ── API Key ──────────────────────────────────────────────────
        let keyHeader = sectionHeader("Gemini API Key")
        stack.addArrangedSubview(row(keyHeader, top: p))

        apiKeyField.placeholderString = "Paste your API key here"
        apiKeyField.font = .monospacedSystemFont(ofSize: 13, weight: .regular)
        apiKeyField.bezelStyle = .roundedBezel
        apiKeyField.cell?.usesSingleLineMode = true
        apiKeyField.cell?.isScrollable = true
        apiKeyField.target = self
        apiKeyField.action = #selector(apiKeyChanged)

        // API key status icon (check / x) next to field
        let cfg = NSImage.SymbolConfiguration(pointSize: 14, weight: .medium)
        apiKeyStatus.image = NSImage(systemSymbolName: "circle", accessibilityDescription: nil)?
            .withSymbolConfiguration(cfg)
        apiKeyStatus.translatesAutoresizingMaskIntoConstraints = false
        apiKeyStatus.widthAnchor.constraint(equalToConstant: 18).isActive = true
        apiKeyStatus.heightAnchor.constraint(equalToConstant: 18).isActive = true

        let keyRow = NSStackView(views: [apiKeyField, apiKeyStatus])
        keyRow.orientation = .horizontal
        keyRow.spacing = 8
        keyRow.translatesAutoresizingMaskIntoConstraints = false
        stack.addArrangedSubview(row(keyRow))

        let linkBtn = NSButton(title: "", target: self, action: #selector(openAIStudio))
        linkBtn.bezelStyle = .inline
        linkBtn.isBordered = false
        linkBtn.attributedTitle = NSAttributedString(
            string: "Get a free key at Google AI Studio →",
            attributes: [.foregroundColor: NSColor.linkColor,
                         .font: NSFont.systemFont(ofSize: 11),
                         .underlineStyle: NSUnderlineStyle.single.rawValue])
        stack.addArrangedSubview(row(linkBtn))

        stack.addArrangedSubview(divider())

        // ── Hotkey ───────────────────────────────────────────────────
        stack.addArrangedSubview(row(sectionHeader("Hotkey Mode"), top: 12))

        holdRadio.target = self; holdRadio.action = #selector(hotkeyChanged(_:))
        stack.addArrangedSubview(row(holdRadio))

        toggleRadio.target = self; toggleRadio.action = #selector(hotkeyChanged(_:))
        stack.addArrangedSubview(row(toggleRadio))

        stack.addArrangedSubview(divider())

        // ── Overlay ──────────────────────────────────────────────────
        overlayToggle.target = self; overlayToggle.action = #selector(overlayChanged)
        stack.addArrangedSubview(row(overlayToggle, top: 12))

        stack.addArrangedSubview(divider())

        // ── Post-processing ──────────────────────────────────────────
        stack.addArrangedSubview(row(sectionHeader("Post-processing"), top: 12))

        let ppNote = NSTextField(wrappingLabelWithString: "Optionally refine the transcript with Gemini before injecting. Adds ~1–2 seconds.")
        ppNote.font = .systemFont(ofSize: 11)
        ppNote.textColor = .secondaryLabelColor
        ppNote.translatesAutoresizingMaskIntoConstraints = false
        stack.addArrangedSubview(row(ppNote))

        for btn in [ppNoneRadio, ppCleanupRadio, ppSummarizeRadio, ppCustomRadio] {
            btn.target = self; btn.action = #selector(ppModeChanged(_:))
            stack.addArrangedSubview(row(btn))
        }

        ppCustomField.placeholderString = "Enter your custom prompt…"
        ppCustomField.font = .systemFont(ofSize: 12)
        ppCustomField.bezelStyle = .roundedBezel
        ppCustomField.cell?.usesSingleLineMode = false
        ppCustomField.cell?.wraps = true
        ppCustomField.cell?.isScrollable = false
        ppCustomField.heightAnchor.constraint(equalToConstant: 56).isActive = true
        ppCustomField.target = self; ppCustomField.action = #selector(ppCustomPromptChanged)
        stack.addArrangedSubview(row(ppCustomField))

        stack.addArrangedSubview(divider())

        // ── Permissions ──────────────────────────────────────────────
        stack.addArrangedSubview(row(sectionHeader("Permissions"), top: 12))

        let permNote = NSTextField(wrappingLabelWithString: "Accessibility is required for the hotkey and text injection. Microphone is required for recording.")
        permNote.font = .systemFont(ofSize: 11)
        permNote.textColor = .secondaryLabelColor
        permNote.translatesAutoresizingMaskIntoConstraints = false
        stack.addArrangedSubview(row(permNote))

        stack.addArrangedSubview(row(micRow))
        stack.addArrangedSubview(row(axRow))

        // ── Version footer ───────────────────────────────────────────
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
        let build   = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1"
        let versionLabel = NSTextField(labelWithString: "Frespr \(version) (\(build))")
        versionLabel.font = .systemFont(ofSize: 10)
        versionLabel.textColor = .tertiaryLabelColor
        versionLabel.alignment = .center
        versionLabel.translatesAutoresizingMaskIntoConstraints = false
        stack.addArrangedSubview(row(versionLabel, top: 4))

        // Bottom padding
        let spacer = NSView()
        spacer.translatesAutoresizingMaskIntoConstraints = false
        spacer.heightAnchor.constraint(equalToConstant: 8).isActive = true
        stack.addArrangedSubview(spacer)

        refreshPermissions()
    }

    private func sectionHeader(_ title: String) -> NSTextField {
        let tf = NSTextField(labelWithString: title)
        tf.font = .boldSystemFont(ofSize: 12)
        return tf
    }

    private func divider() -> NSView {
        let box = NSBox()
        box.boxType = .separator
        box.translatesAutoresizingMaskIntoConstraints = false
        // Wrap in a container with horizontal padding
        let container = NSView()
        container.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(box)
        NSLayoutConstraint.activate([
            box.topAnchor.constraint(equalTo: container.topAnchor, constant: 8),
            box.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -8),
            box.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 20),
            box.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -20),
            box.heightAnchor.constraint(equalToConstant: 1),
        ])
        return container
    }

    // MARK: - Values

    private func loadValues() {
        let s = AppSettings.shared
        apiKeyField.stringValue = s.geminiAPIKey
        holdRadio.state   = s.hotkeyMode == .hold   ? .on : .off
        toggleRadio.state = s.hotkeyMode == .toggle  ? .on : .off
        overlayToggle.state = s.showOverlay ? .on : .off
        updateAPIKeyStatus(key: s.geminiAPIKey)
        updatePPRadios(mode: s.postProcessingMode)
        ppCustomField.stringValue = s.customPostProcessingPrompt
        updatePPCustomFieldVisibility()
    }

    private func updatePPRadios(mode: PostProcessingMode) {
        ppNoneRadio.state      = mode == .none      ? .on : .off
        ppCleanupRadio.state   = mode == .cleanup   ? .on : .off
        ppSummarizeRadio.state = mode == .summarize ? .on : .off
        ppCustomRadio.state    = mode == .custom    ? .on : .off
    }

    private func updatePPCustomFieldVisibility() {
        ppCustomField.isHidden = AppSettings.shared.postProcessingMode != .custom
    }

    private func updateAPIKeyStatus(key: String) {
        let cfg = NSImage.SymbolConfiguration(pointSize: 14, weight: .medium)
        if key.isEmpty {
            apiKeyStatus.image = NSImage(systemSymbolName: "circle.dashed",
                                         accessibilityDescription: nil)?.withSymbolConfiguration(cfg)
            apiKeyStatus.contentTintColor = .tertiaryLabelColor
        } else {
            apiKeyStatus.image = NSImage(systemSymbolName: "checkmark.circle.fill",
                                         accessibilityDescription: nil)?.withSymbolConfiguration(cfg)
            apiKeyStatus.contentTintColor = .systemGreen
        }
    }

    private func refreshPermissions() {
        let pm = PermissionManager.shared
        micRow.setGranted(pm.microphoneAuthorized) { [weak self] in
            Task {
                _ = await PermissionManager.shared.requestMicrophoneAccess()
                await MainActor.run { self?.refreshPermissions() }
            }
        }
        axRow.setGranted(pm.accessibilityAuthorized) { [weak self] in
            PermissionManager.shared.requestAccessibilityAccess()
            self?.refreshPermissions()
        }
    }

    // MARK: - Actions

    @objc private func apiKeyChanged() {
        let key = apiKeyField.stringValue
        AppSettings.shared.geminiAPIKey = key
        updateAPIKeyStatus(key: key)
    }

    @objc private func hotkeyChanged(_ sender: NSButton) {
        // Manually enforce mutual exclusivity — radio buttons only auto-deselect
        // each other when in the same direct superview, not inside stack subviews.
        let isHold = sender === holdRadio
        holdRadio.state   = isHold ? .on : .off
        toggleRadio.state = isHold ? .off : .on
        AppSettings.shared.hotkeyMode = isHold ? .hold : .toggle
    }

    @objc private func overlayChanged() { AppSettings.shared.showOverlay = overlayToggle.state == .on }
    @objc private func openAIStudio() { NSWorkspace.shared.open(URL(string: "https://aistudio.google.com/app/apikey")!) }

    @objc private func ppModeChanged(_ sender: NSButton) {
        let mode: PostProcessingMode
        switch sender {
        case ppNoneRadio:      mode = .none
        case ppCleanupRadio:   mode = .cleanup
        case ppSummarizeRadio: mode = .summarize
        default:               mode = .custom
        }
        updatePPRadios(mode: mode)
        AppSettings.shared.postProcessingMode = mode
        updatePPCustomFieldVisibility()
    }

    @objc private func ppCustomPromptChanged() {
        AppSettings.shared.customPostProcessingPrompt = ppCustomField.stringValue
    }

    // MARK: - Show

    func showSettings() {
        installEditMenu()
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        DispatchQueue.main.async { [weak self] in
            guard let self, let w = self.window else { return }
            w.makeFirstResponder(self.apiKeyField)
        }
    }

    private func installEditMenu() {
        let mainMenu = NSMenu()

        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(NSMenuItem(title: "Quit Frespr", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        appItem.submenu = appMenu
        mainMenu.addItem(appItem)

        let editItem = NSMenuItem()
        let editMenu = NSMenu(title: "Edit")
        editMenu.addItem(NSMenuItem(title: "Cut",        action: #selector(NSText.cut(_:)),        keyEquivalent: "x"))
        editMenu.addItem(NSMenuItem(title: "Copy",       action: #selector(NSText.copy(_:)),       keyEquivalent: "c"))
        editMenu.addItem(NSMenuItem(title: "Paste",      action: #selector(NSText.paste(_:)),      keyEquivalent: "v"))
        editMenu.addItem(NSMenuItem(title: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a"))
        editItem.submenu = editMenu
        mainMenu.addItem(editItem)

        NSApp.mainMenu = mainMenu
    }

    // MARK: - NSWindowDelegate

    func windowWillClose(_ notification: Notification) {
        AppSettings.shared.geminiAPIKey = apiKeyField.stringValue
        AppSettings.shared.customPostProcessingPrompt = ppCustomField.stringValue
        NSApp.mainMenu = nil
        NSApp.setActivationPolicy(.accessory)
        onClose?()
    }
}

// MARK: - PermissionRowView

final class PermissionRowView: NSView {
    private let icon  = NSImageView()
    private let label: NSTextField
    private let btn   = NSButton()
    private var grantAction: (() -> Void)?

    init(label: String) {
        self.label = NSTextField(labelWithString: label)
        super.init(frame: .zero)
        for v in [icon, self.label, btn] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            addSubview(v)
        }
        btn.title = "Grant Access"
        btn.bezelStyle = .rounded
        btn.controlSize = .small
        btn.target = self; btn.action = #selector(tapped)

        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: leadingAnchor),
            icon.centerYAnchor.constraint(equalTo: centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 16),
            icon.heightAnchor.constraint(equalToConstant: 16),

            self.label.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 6),
            self.label.centerYAnchor.constraint(equalTo: centerYAnchor),

            btn.trailingAnchor.constraint(equalTo: trailingAnchor),
            btn.centerYAnchor.constraint(equalTo: centerYAnchor),

            heightAnchor.constraint(equalToConstant: 22),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    func setGranted(_ granted: Bool, action: @escaping () -> Void) {
        grantAction = action
        let cfg = NSImage.SymbolConfiguration(pointSize: 13, weight: .regular)
        icon.image = NSImage(systemSymbolName: granted ? "checkmark.circle.fill" : "xmark.circle.fill",
                             accessibilityDescription: nil)?.withSymbolConfiguration(cfg)
        icon.contentTintColor = granted ? .systemGreen : .systemRed
        btn.isHidden = granted
    }

    @objc private func tapped() { grantAction?() }
}
