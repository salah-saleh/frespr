import AppKit

// MARK: - SettingsWindowController
//
// Pure-AppKit settings window. No SwiftUI — required so text fields accept
// keyboard input without switching activation policy tricks beyond the one
// already in showSettings() / windowWillClose(_:).
//
// Layout approach: a scrolling NSStackView containing card-style NSBox sections.
// Each section is a rounded box with a subtle fill, containing its own vertical
// NSStackView of rows. This gives clear visual grouping without a sidebar.
//
// All action handlers, delegate methods, and data-loading logic are unchanged
// from the previous implementation — only buildUI() and the window size changed.

final class SettingsWindowController: NSWindowController, NSWindowDelegate, NSTextFieldDelegate {

    var onClose: (() -> Void)?

    /// Set to true before calling showSettings() to display the v2.0 migration banner.
    var showMigrationNotice: Bool = false

    // MARK: - Design tokens

    // Brand blue used for section headers and active accents
    private static let brandBlue = NSColor(red: 0.357, green: 0.612, blue: 0.965, alpha: 1)
    // Card background — slightly lighter than window bg
    private static let cardBg    = NSColor(white: 1, alpha: 0.04)
    // Separator color inside cards
    private static let cardSep   = NSColor(white: 1, alpha: 0.07)
    // Window background
    private static let windowBg  = NSColor(red: 0.043, green: 0.067, blue: 0.110, alpha: 1)

    // MARK: - Subviews

    private let migrationBanner: NSView = {
        let container = NSView()
        container.wantsLayer = true
        container.layer?.backgroundColor = NSColor(red: 0.8, green: 0.6, blue: 0.1, alpha: 0.18).cgColor
        container.layer?.cornerRadius = 10
        let icon = NSImageView()
        icon.image = NSImage(systemSymbolName: "exclamationmark.triangle.fill", accessibilityDescription: nil)
        icon.contentTintColor = NSColor(red: 1.0, green: 0.85, blue: 0.4, alpha: 1)
        icon.translatesAutoresizingMaskIntoConstraints = false
        icon.widthAnchor.constraint(equalToConstant: 16).isActive = true
        icon.heightAnchor.constraint(equalToConstant: 16).isActive = true
        let label = NSTextField(wrappingLabelWithString:
            "Frespr now uses Deepgram for transcription — faster and more accurate. " +
            "Your Gemini key still works for post-processing. " +
            "Add a free Deepgram API key below to continue recording.")
        label.font = .systemFont(ofSize: 12)
        label.textColor = NSColor(red: 1.0, green: 0.85, blue: 0.4, alpha: 1)
        label.translatesAutoresizingMaskIntoConstraints = false
        let hStack = NSStackView(views: [icon, label])
        hStack.orientation = .horizontal
        hStack.alignment = .top
        hStack.spacing = 8
        hStack.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(hStack)
        NSLayoutConstraint.activate([
            hStack.topAnchor.constraint(equalTo: container.topAnchor, constant: 12),
            hStack.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -12),
            hStack.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 14),
            hStack.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -14),
        ])
        return container
    }()

    // API key fields
    private let apiKeyField    = NSTextField()
    private let apiKeyStatus   = NSImageView()
    private let apiKeyEditBtn  = NSButton()
    private var apiKeyIsEditing = false
    private var silenceMouseMonitor: Any?  // local mouse-down monitor to commit timeout field on outside click
    private let dgKeyField     = NSTextField()
    private let dgKeyStatus    = NSImageView()
    private let dgKeyEditBtn   = NSButton()
    private var dgKeyIsEditing  = false
    private let dgBackendLabel: NSTextField = {
        let tf = NSTextField(labelWithString: "")
        tf.font = .systemFont(ofSize: 11)
        tf.textColor = .secondaryLabelColor
        return tf
    }()

    // Silence detection
    private let silenceCheck     = NSButton(checkboxWithTitle: "Auto-stop after silence", target: nil, action: nil)
    private let silenceTimeout   = NSTextField()
    private let silenceTimeoutStepper = NSStepper()
    private let silenceTimeoutLabel   = NSTextField(labelWithString: "seconds")

    // Post-processing
    private let ppNoneRadio      = NSButton(radioButtonWithTitle: PostProcessingMode.none.displayName,      target: nil, action: nil)
    private let ppCleanupRadio   = NSButton(radioButtonWithTitle: PostProcessingMode.cleanup.displayName,   target: nil, action: nil)
    private let ppSummarizeRadio = NSButton(radioButtonWithTitle: PostProcessingMode.summarize.displayName, target: nil, action: nil)
    private let ppCustomRadio    = NSButton(radioButtonWithTitle: PostProcessingMode.custom.displayName,    target: nil, action: nil)
    private let ppCustomField    = NSTextField()

    // Hotkey
    private let hotKeyPopup      = NSPopUpButton()

    // Output
    private let clipboardCheck   = NSButton(checkboxWithTitle: "Copy transcript to clipboard", target: nil, action: nil)
    private let soundCheck       = NSButton(checkboxWithTitle: "Sound feedback (start / stop / success)", target: nil, action: nil)

    // Translation
    private let translationCheck = NSButton(checkboxWithTitle: "Translate transcription before injecting", target: nil, action: nil)
    private let translationSourcePopup = NSPopUpButton()
    private let translationTargetPopup = NSPopUpButton()
    private let favoritesStack   = NSStackView()
    private let addFavPopup      = NSPopUpButton()

    // Permissions
    private let micRow = PermissionRowView(label: "Microphone")
    private let axRow  = PermissionRowView(label: "Accessibility  (hotkey + text injection)")

    // MARK: - Init

    convenience init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 560, height: 720),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.minSize  = NSSize(width: 560, height: 420)
        window.maxSize  = NSSize(width: 560, height: 1400)
        window.title    = "Frespr Settings"
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: .darkAqua)
        window.titlebarAppearsTransparent = true
        window.backgroundColor = SettingsWindowController.windowBg
        self.init(window: window)
        window.delegate = self
        buildUI()
        loadValues()
    }

    // MARK: - Build UI

    private func buildUI() {
        guard let content = window?.contentView else { return }

        // Outer scroll view fills the window
        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller   = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers    = true
        scrollView.drawsBackground       = false
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(scrollView)
        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: content.topAnchor),
            scrollView.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: content.bottomAnchor),
        ])

        // Root stack — vertical, one card per section, fills scroll view width.
        // alignment = .leading + explicit trailing constraints on each card (added below via padded()).
        let root = NSStackView()
        root.orientation = .vertical
        root.alignment   = .leading
        root.spacing     = 12
        root.translatesAutoresizingMaskIntoConstraints = false
        scrollView.documentView = root
        NSLayoutConstraint.activate([
            root.leadingAnchor.constraint(equalTo: scrollView.contentView.leadingAnchor),
            root.trailingAnchor.constraint(equalTo: scrollView.contentView.trailingAnchor),
            root.topAnchor.constraint(equalTo: scrollView.contentView.topAnchor),
        ])

        let pad: CGFloat = 20  // outer horizontal padding

        // Convenience: wrap a view in a full-width padded container.
        // The container itself is pinned to root's full width via a widthAnchor after being added,
        // so cards always fill the scroll view horizontally.
        func padded(_ view: NSView, top: CGFloat = 0, bottom: CGFloat = 0) -> NSView {
            let c = NSView()
            c.translatesAutoresizingMaskIntoConstraints = false
            view.translatesAutoresizingMaskIntoConstraints = false
            c.addSubview(view)
            NSLayoutConstraint.activate([
                view.topAnchor.constraint(equalTo: c.topAnchor, constant: top),
                view.bottomAnchor.constraint(equalTo: c.bottomAnchor, constant: -bottom),
                view.leadingAnchor.constraint(equalTo: c.leadingAnchor, constant: pad),
                view.trailingAnchor.constraint(equalTo: c.trailingAnchor, constant: -pad),
            ])
            return c
        }

        // After adding a padded container to root, bind its width to the scroll content view
        // so it fills full width regardless of content size.
        func pinWidth(_ container: NSView) {
            container.widthAnchor.constraint(equalTo: scrollView.contentView.widthAnchor).isActive = true
        }

        // ── Migration banner ───────────────────────────────────────────
        migrationBanner.translatesAutoresizingMaskIntoConstraints = false
        migrationBanner.isHidden = true
        let bannerContainer = padded(migrationBanner, top: pad, bottom: 0)
        // Hide the container too so it takes no space when banner is not needed
        bannerContainer.isHidden = true
        root.addArrangedSubview(bannerContainer)
        pinWidth(bannerContainer)

        // ── Deepgram API Key card (required) ───────────────────────────
        let dgCard = makeCard()
        let dgInner = cardStack(in: dgCard)

        // Header row: title + subtitle on left, "Get a key →" link on right (hidden when key set)
        let dgLinkBtn = makeLinkButton(title: "Get a free key →", action: #selector(openDeepgramConsole))

        let dgHeaderRow = makeCardHeaderRow(
            title: "Deepgram API Key",
            subtitle: "Required — real-time transcription",
            accessory: dgLinkBtn
        )
        dgInner.addArrangedSubview(dgHeaderRow)
        dgInner.addArrangedSubview(cardSeparator())

        // Key input row
        dgKeyField.placeholderString = "Paste your Deepgram API key"
        styleKeyField(dgKeyField)
        dgKeyField.target = self
        dgKeyField.action = #selector(dgKeySavePressed)

        styleKeyStatus(dgKeyStatus)
        styleKeyEditButton(dgKeyEditBtn, action: #selector(dgKeyEditPressed))

        let dgKeyRow = NSStackView(views: [dgKeyField, dgKeyStatus, dgKeyEditBtn])
        dgKeyRow.orientation = .horizontal
        dgKeyRow.spacing = 8
        dgInner.addArrangedSubview(dgKeyRow)

        // Status label (Active / Add key above)
        dgBackendLabel.translatesAutoresizingMaskIntoConstraints = false
        dgInner.addArrangedSubview(dgBackendLabel)

        let dgContainer = padded(dgCard, top: 0, bottom: 0)
        root.addArrangedSubview(dgContainer)
        pinWidth(dgContainer)

        // ── Gemini API Key card (optional) ─────────────────────────────
        let gemCard = makeCard()
        let gemInner = cardStack(in: gemCard)

        let gemLinkBtn = makeLinkButton(title: "Get a free key →", action: #selector(openAIStudio))

        let gemHeaderRow = makeCardHeaderRow(
            title: "Gemini API Key",
            subtitle: "Optional — enables post-processing & translation",
            accessory: gemLinkBtn
        )
        gemInner.addArrangedSubview(gemHeaderRow)
        gemInner.addArrangedSubview(cardSeparator())

        apiKeyField.placeholderString = "Paste your Gemini API key"
        styleKeyField(apiKeyField)
        apiKeyField.target = self
        apiKeyField.action = #selector(apiKeySavePressed)

        styleKeyStatus(apiKeyStatus)
        styleKeyEditButton(apiKeyEditBtn, action: #selector(apiKeyEditPressed))

        let gemKeyRow = NSStackView(views: [apiKeyField, apiKeyStatus, apiKeyEditBtn])
        gemKeyRow.orientation = .horizontal
        gemKeyRow.spacing = 8
        gemInner.addArrangedSubview(gemKeyRow)

        let gemContainer = padded(gemCard, top: 0, bottom: 0)
        root.addArrangedSubview(gemContainer)
        pinWidth(gemContainer)

        // ── Hotkey + Silence card ──────────────────────────────────────
        let inputCard = makeCard()
        let inputInner = cardStack(in: inputCard)

        inputInner.addArrangedSubview(makeCardHeader(title: "Recording"))
        inputInner.addArrangedSubview(cardSeparator())

        // Hotkey row
        let hotkeyLabel = makeRowLabel("Hotkey")
        for option in HotKeyOption.allCases { hotKeyPopup.addItem(withTitle: option.label) }
        hotKeyPopup.target = self; hotKeyPopup.action = #selector(hotKeyChanged)
        hotKeyPopup.setContentHuggingPriority(.defaultLow, for: .horizontal)

        let hotkeyRow = NSStackView(views: [hotkeyLabel, hotKeyPopup])
        hotkeyRow.orientation = .horizontal
        hotkeyRow.spacing = 8
        // Label hugs left, popup hugs right
        hotkeyLabel.setContentHuggingPriority(.defaultHigh, for: .horizontal)
        hotKeyPopup.setContentHuggingPriority(.defaultLow, for: .horizontal)
        inputInner.addArrangedSubview(hotkeyRow)

        let hotkeyNote = makeNote("Fn/Globe requires System Settings → Keyboard → Press Globe key → Do Nothing")
        inputInner.addArrangedSubview(hotkeyNote)

        inputInner.addArrangedSubview(cardSeparator())

        // Silence detection row
        silenceCheck.target = self; silenceCheck.action = #selector(silenceCheckChanged)
        inputInner.addArrangedSubview(silenceCheck)

        silenceTimeout.bezelStyle = .roundedBezel
        silenceTimeout.alignment  = .center
        silenceTimeout.font       = .systemFont(ofSize: 13)
        silenceTimeout.widthAnchor.constraint(equalToConstant: 48).isActive = true
        silenceTimeout.target     = self
        silenceTimeout.action     = #selector(silenceTimeoutChanged)
        silenceTimeout.delegate   = self

        silenceTimeoutStepper.minValue    = 5
        silenceTimeoutStepper.maxValue    = 60
        silenceTimeoutStepper.increment   = 1
        silenceTimeoutStepper.valueWraps  = false
        silenceTimeoutStepper.target = self; silenceTimeoutStepper.action = #selector(silenceStepperChanged(_:))

        let silenceLabel = makeRowLabel("Stop after")
        let silenceRow = NSStackView(views: [silenceLabel, silenceTimeout, silenceTimeoutStepper, silenceTimeoutLabel])
        silenceRow.orientation = .horizontal
        silenceRow.spacing = 6
        inputInner.addArrangedSubview(silenceRow)

        let inputContainer = padded(inputCard, top: 0, bottom: 0)
        root.addArrangedSubview(inputContainer)
        pinWidth(inputContainer)

        // ── Post-processing card ───────────────────────────────────────
        let ppCard = makeCard()
        let ppInner = cardStack(in: ppCard)

        ppInner.addArrangedSubview(makeCardHeader(title: "Post-processing"))
        ppInner.addArrangedSubview(cardSeparator())

        let ppNote = makeNote("Optionally refine the transcript with Gemini before injecting. Requires a Gemini key.")
        ppInner.addArrangedSubview(ppNote)

        for btn in [ppNoneRadio, ppCleanupRadio, ppSummarizeRadio, ppCustomRadio] {
            btn.target = self; btn.action = #selector(ppModeChanged(_:))
            ppInner.addArrangedSubview(btn)
        }

        ppCustomField.placeholderString = "Enter your custom prompt…"
        ppCustomField.font = .systemFont(ofSize: 12)
        ppCustomField.bezelStyle = .roundedBezel
        ppCustomField.cell?.usesSingleLineMode = false
        ppCustomField.cell?.wraps = true
        ppCustomField.cell?.isScrollable = false
        ppCustomField.heightAnchor.constraint(equalToConstant: 60).isActive = true
        ppCustomField.target   = self
        ppCustomField.action   = #selector(ppCustomPromptChanged)
        ppCustomField.delegate = self
        ppInner.addArrangedSubview(ppCustomField)

        let ppContainer = padded(ppCard, top: 0, bottom: 0)
        root.addArrangedSubview(ppContainer)
        pinWidth(ppContainer)

        // ── Output card ────────────────────────────────────────────────
        let outputCard = makeCard()
        let outputInner = cardStack(in: outputCard)

        outputInner.addArrangedSubview(makeCardHeader(title: "Output"))
        outputInner.addArrangedSubview(cardSeparator())

        clipboardCheck.target = self; clipboardCheck.action = #selector(clipboardCheckChanged)
        outputInner.addArrangedSubview(clipboardCheck)

        soundCheck.target = self; soundCheck.action = #selector(soundCheckChanged)
        outputInner.addArrangedSubview(soundCheck)

        let outputContainer = padded(outputCard, top: 0, bottom: 0)
        root.addArrangedSubview(outputContainer)
        pinWidth(outputContainer)

        // ── Translation card ───────────────────────────────────────────
        let transCard = makeCard()
        let transInner = cardStack(in: transCard)

        transInner.addArrangedSubview(makeCardHeader(title: "Translation"))
        transInner.addArrangedSubview(cardSeparator())

        translationCheck.target = self; translationCheck.action = #selector(translationCheckChanged)
        transInner.addArrangedSubview(translationCheck)

        transInner.addArrangedSubview(cardSeparator())

        // Speak in row
        translationSourcePopup.addItem(withTitle: "Auto-detect")
        translationSourcePopup.menu?.addItem(.separator())
        for lang in kSupportedLanguages { translationSourcePopup.addItem(withTitle: lang) }
        translationSourcePopup.target = self; translationSourcePopup.action = #selector(translationSourceChanged)
        let speakInRow = makeLabelPopupRow("Speak in", popup: translationSourcePopup)
        transInner.addArrangedSubview(speakInRow)

        // Translate to row
        for lang in kSupportedLanguages { translationTargetPopup.addItem(withTitle: lang) }
        translationTargetPopup.target = self; translationTargetPopup.action = #selector(translationTargetChanged)
        let translateToRow = makeLabelPopupRow("Translate to", popup: translationTargetPopup)
        transInner.addArrangedSubview(translateToRow)

        transInner.addArrangedSubview(cardSeparator())

        // Favorites
        let favsHeader = makeRowLabel("Quick-switch languages")
        transInner.addArrangedSubview(favsHeader)

        favoritesStack.orientation = .vertical
        favoritesStack.alignment   = .leading
        favoritesStack.spacing     = 4
        favoritesStack.translatesAutoresizingMaskIntoConstraints = false
        transInner.addArrangedSubview(favoritesStack)

        addFavPopup.target = self; addFavPopup.action = #selector(addFavorite)
        addFavPopup.bezelStyle = .rounded
        addFavPopup.controlSize = .small
        transInner.addArrangedSubview(addFavPopup)

        let favsNote = makeNote("Up to 6 favorites. Click the translation pill during recording to cycle through them.")
        transInner.addArrangedSubview(favsNote)

        let transContainer = padded(transCard, top: 0, bottom: 0)
        root.addArrangedSubview(transContainer)
        pinWidth(transContainer)

        // ── Permissions card ───────────────────────────────────────────
        let permCard = makeCard()
        let permInner = cardStack(in: permCard)

        permInner.addArrangedSubview(makeCardHeader(title: "Permissions"))
        permInner.addArrangedSubview(cardSeparator())

        permInner.addArrangedSubview(micRow)
        permInner.addArrangedSubview(cardSeparator())
        permInner.addArrangedSubview(axRow)

        let permContainer = padded(permCard, top: 0, bottom: 0)
        root.addArrangedSubview(permContainer)
        pinWidth(permContainer)

        // ── Version footer ─────────────────────────────────────────────
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
        let build   = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1"
        let versionLabel = NSTextField(labelWithString: "Frespr \(version) (\(build))")
        versionLabel.font      = .systemFont(ofSize: 10)
        versionLabel.textColor = .tertiaryLabelColor
        versionLabel.alignment = .center
        let footerContainer = padded(versionLabel, top: 4, bottom: 16)
        root.addArrangedSubview(footerContainer)
        pinWidth(footerContainer)

        refreshPermissions()

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(externalTranslationChanged),
            name: .translationSettingsChanged,
            object: nil
        )
    }

    // MARK: - Card building helpers

    /// Creates a rounded card NSBox with the standard background and border.
    private func makeCard() -> NSBox {
        let box = NSBox()
        box.boxType         = .custom
        box.fillColor       = SettingsWindowController.cardBg
        box.borderColor     = NSColor(white: 1, alpha: 0.08)
        box.borderWidth     = 1
        box.cornerRadius    = 12
        box.translatesAutoresizingMaskIntoConstraints = false
        return box
    }

    /// Creates a vertical NSStackView pinned to the card's content view with standard insets.
    /// alignment = .left; rows fill width because they are pinned leading+trailing to the card.
    private func cardStack(in card: NSBox) -> NSStackView {
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment   = .leading
        stack.spacing     = 10
        stack.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: card.topAnchor, constant: 14),
            stack.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -14),
            stack.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 16),
            stack.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -16),
        ])
        return stack
    }

    /// A thin horizontal separator line inside a card.
    /// With cardStack alignment = .fill this stretches automatically to full card width.
    private func cardSeparator() -> NSView {
        let line = NSView()
        line.wantsLayer = true
        line.layer?.backgroundColor = SettingsWindowController.cardSep.cgColor
        line.translatesAutoresizingMaskIntoConstraints = false
        line.heightAnchor.constraint(equalToConstant: 1).isActive = true
        return line
    }

    /// Simple section header label inside a card.
    private func makeCardHeader(title: String) -> NSTextField {
        let tf = NSTextField(labelWithString: title)
        tf.font      = .systemFont(ofSize: 13, weight: .semibold)
        tf.textColor = .labelColor
        return tf
    }

    /// Card header row: title+subtitle stack on left, optional accessory view on right.
    private func makeCardHeaderRow(title: String, subtitle: String, accessory: NSView?) -> NSView {
        let titleLabel = NSTextField(labelWithString: title)
        titleLabel.font      = .systemFont(ofSize: 13, weight: .semibold)
        titleLabel.textColor = .labelColor

        let subLabel = NSTextField(labelWithString: subtitle)
        subLabel.font      = .systemFont(ofSize: 11)
        subLabel.textColor = .secondaryLabelColor

        let titleStack = NSStackView(views: [titleLabel, subLabel])
        titleStack.orientation = .vertical
        titleStack.alignment   = .leading
        titleStack.spacing     = 2

        if let acc = accessory {
            let row = NSStackView(views: [titleStack, NSView(), acc])
            row.orientation = .horizontal
            row.spacing     = 8
            row.alignment   = .centerY
            if let spacer = row.arrangedSubviews[1] as NSView? {
                spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
            }
            return row
        } else {
            return titleStack
        }
    }

    /// Small secondary label used as a row prefix.
    private func makeRowLabel(_ text: String) -> NSTextField {
        let tf = NSTextField(labelWithString: text)
        tf.font      = .systemFont(ofSize: 13)
        tf.textColor = .labelColor
        return tf
    }

    /// Dim helper note text below a control.
    private func makeNote(_ text: String) -> NSTextField {
        let tf = NSTextField(wrappingLabelWithString: text)
        tf.font      = .systemFont(ofSize: 11)
        tf.textColor = .tertiaryLabelColor
        tf.translatesAutoresizingMaskIntoConstraints = false
        return tf
    }

    /// Inline link-style button.
    private func makeLinkButton(title: String, action: Selector) -> NSButton {
        let btn = NSButton(title: "", target: self, action: action)
        btn.bezelStyle  = .inline
        btn.isBordered  = false
        btn.attributedTitle = NSAttributedString(
            string: title,
            attributes: [
                .foregroundColor: NSColor.linkColor,
                .font: NSFont.systemFont(ofSize: 11),
                .underlineStyle: NSUnderlineStyle.single.rawValue,
            ])
        return btn
    }

    /// Label + popup button in a horizontal row, label left, popup stretches right.
    private func makeLabelPopupRow(_ labelText: String, popup: NSPopUpButton) -> NSView {
        let label = makeRowLabel(labelText)
        label.setContentHuggingPriority(.defaultHigh, for: .horizontal)
        popup.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let row = NSStackView(views: [label, popup])
        row.orientation = .horizontal
        row.spacing     = 8
        row.alignment   = .centerY
        return row
    }

    // MARK: - Key field helpers

    private func styleKeyField(_ field: NSTextField) {
        field.font             = .monospacedSystemFont(ofSize: 12, weight: .regular)
        field.bezelStyle       = .roundedBezel
        field.cell?.usesSingleLineMode = true
        field.cell?.isScrollable       = true
    }

    private func styleKeyStatus(_ view: NSImageView) {
        view.translatesAutoresizingMaskIntoConstraints = false
        view.widthAnchor.constraint(equalToConstant: 18).isActive = true
        view.heightAnchor.constraint(equalToConstant: 18).isActive = true
    }

    private func styleKeyEditButton(_ btn: NSButton, action: Selector) {
        btn.bezelStyle   = .rounded
        btn.controlSize  = .small
        btn.target       = self
        btn.action       = action
    }

    // MARK: - Notification handler

    @objc private func externalTranslationChanged() {
        let s = AppSettings.shared
        translationCheck.state = s.translationEnabled ? .on : .off
        translationSourcePopup.selectItem(withTitle: s.translationSourceLanguage)
        if translationSourcePopup.indexOfSelectedItem < 0 { translationSourcePopup.selectItem(at: 0) }
        translationTargetPopup.selectItem(withTitle: s.translationTargetLanguage)
        if translationTargetPopup.indexOfSelectedItem < 0 { translationTargetPopup.selectItem(withTitle: "English") }
        updateTranslationRowsEnabled()
    }

    // MARK: - Values

    private func loadValues() {
        let s = AppSettings.shared

        // Gemini key
        let key = s.geminiAPIKey
        apiKeyField.stringValue = key
        updateAPIKeyStatus(key: key)
        setAPIKeyEditing(key.isEmpty)

        // Deepgram key
        let dgKey = s.deepgramAPIKey
        updateDGKeyStatus(key: dgKey)
        setDGKeyEditing(dgKey.isEmpty)
        updateDGBackendLabel()

        // Silence
        silenceCheck.state = s.silenceDetectionEnabled ? .on : .off
        silenceTimeout.integerValue = s.silenceTimeoutSeconds
        silenceTimeoutStepper.integerValue = s.silenceTimeoutSeconds
        updateSilenceRowEnabled()

        // Post-processing
        updatePPRadios(mode: s.postProcessingMode)
        ppCustomField.stringValue = s.customPostProcessingPrompt
        updatePPCustomFieldVisibility()

        // Hotkey
        if let idx = HotKeyOption.allCases.firstIndex(of: s.hotKeyOption) {
            hotKeyPopup.selectItem(at: idx)
        }

        // Output
        clipboardCheck.state = s.copyToClipboard ? .on : .off
        soundCheck.state     = s.soundFeedbackEnabled ? .on : .off

        // Translation
        translationCheck.state = s.translationEnabled ? .on : .off
        translationSourcePopup.selectItem(withTitle: s.translationSourceLanguage)
        if translationSourcePopup.indexOfSelectedItem < 0 { translationSourcePopup.selectItem(at: 0) }
        translationTargetPopup.selectItem(withTitle: s.translationTargetLanguage)
        if translationTargetPopup.indexOfSelectedItem < 0 { translationTargetPopup.selectItem(withTitle: "English") }
        updateTranslationRowsEnabled()
        loadFavorites()
    }

    private func updateSilenceRowEnabled() {
        let on = AppSettings.shared.silenceDetectionEnabled
        silenceTimeout.isEnabled        = on
        silenceTimeoutStepper.isEnabled = on
        silenceTimeoutLabel.textColor   = on ? .labelColor : .disabledControlTextColor
    }

    private func updatePPRadios(mode: PostProcessingMode) {
        ppNoneRadio.state      = mode == .none      ? .on : .off
        ppCleanupRadio.state   = mode == .cleanup   ? .on : .off
        ppSummarizeRadio.state = mode == .summarize ? .on : .off
        ppCustomRadio.state    = mode == .custom    ? .on : .off
    }

    private func updateTranslationRowsEnabled() {
        let on = translationCheck.state == .on
        translationSourcePopup.isEnabled = on
        translationTargetPopup.isEnabled = on
    }

    private func loadFavorites() {
        for v in favoritesStack.arrangedSubviews {
            favoritesStack.removeArrangedSubview(v)
            v.removeFromSuperview()
        }

        let favs = AppSettings.shared.translationFavorites
        for (i, lang) in favs.enumerated() {
            let label = NSTextField(labelWithString: lang)
            label.font = .systemFont(ofSize: 12)
            let removeBtn = NSButton(title: "−", target: self, action: #selector(removeFavorite(_:)))
            removeBtn.bezelStyle  = .rounded
            removeBtn.controlSize = .small
            removeBtn.tag = i
            let favRow = NSStackView(views: [label, NSView(), removeBtn])
            favRow.orientation = .horizontal
            favRow.spacing     = 6
            favRow.translatesAutoresizingMaskIntoConstraints = false
            if let spacer = favRow.arrangedSubviews[1] as NSView? {
                spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
            }
            favoritesStack.addArrangedSubview(favRow)
        }

        if favs.isEmpty {
            let empty = NSTextField(labelWithString: "(none)")
            empty.font      = .systemFont(ofSize: 12)
            empty.textColor = .tertiaryLabelColor
            favoritesStack.addArrangedSubview(empty)
        }

        addFavPopup.removeAllItems()
        addFavPopup.addItem(withTitle: "＋ Add language…")
        let available = kSupportedLanguages.filter { !favs.contains($0) }
        for lang in available { addFavPopup.addItem(withTitle: lang) }
        addFavPopup.isEnabled = favs.count < 6
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

    private func setAPIKeyEditing(_ editing: Bool) {
        apiKeyIsEditing          = editing
        apiKeyField.isEditable   = editing
        apiKeyField.isSelectable = editing
        apiKeyField.backgroundColor = editing ? .textBackgroundColor : .controlBackgroundColor

        if editing {
            apiKeyField.stringValue = AppSettings.shared.geminiAPIKey
            apiKeyEditBtn.title     = "Save"
        } else {
            let key = AppSettings.shared.geminiAPIKey
            apiKeyField.stringValue = key.isEmpty ? "" : mask(key)
            apiKeyEditBtn.title     = "Edit"
        }
    }

    private func updateDGKeyStatus(key: String) {
        let cfg = NSImage.SymbolConfiguration(pointSize: 14, weight: .medium)
        if key.isEmpty {
            dgKeyStatus.image = NSImage(systemSymbolName: "circle.dashed",
                                        accessibilityDescription: "no key")?.withSymbolConfiguration(cfg)
            dgKeyStatus.contentTintColor = .tertiaryLabelColor
        } else {
            dgKeyStatus.image = NSImage(systemSymbolName: "checkmark.circle.fill",
                                        accessibilityDescription: "key set")?.withSymbolConfiguration(cfg)
            dgKeyStatus.contentTintColor = .systemGreen
        }
    }

    private func setDGKeyEditing(_ editing: Bool) {
        dgKeyIsEditing          = editing
        dgKeyField.isEditable   = editing
        dgKeyField.isSelectable = editing
        dgKeyField.backgroundColor = editing ? .textBackgroundColor : .controlBackgroundColor

        if editing {
            dgKeyField.stringValue  = AppSettings.shared.deepgramAPIKey
            dgKeyEditBtn.title      = "Save"
        } else {
            let key = AppSettings.shared.deepgramAPIKey
            dgKeyField.stringValue  = key.isEmpty ? "" : mask(key)
            dgKeyEditBtn.title      = "Edit"
        }
    }

    private func updateDGBackendLabel() {
        let hasDG = !AppSettings.shared.deepgramAPIKey.isEmpty
        // v2.0: Deepgram is the sole transcription backend; no Gemini Live fallback.
        dgBackendLabel.stringValue = hasDG
            ? "✓  Active — nova-3, real-time streaming"
            : "Add key above to enable transcription"
        dgBackendLabel.textColor = hasDG ? .systemGreen : .secondaryLabelColor
        dgBackendLabel.isHidden  = false
    }

    private func mask(_ key: String) -> String {
        guard key.count > 8 else { return String(repeating: "•", count: key.count) }
        let suffix = String(key.suffix(4))
        return String(repeating: "•", count: key.count - 4) + suffix
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

    @objc private func apiKeyEditPressed() {
        if apiKeyIsEditing {
            let key = apiKeyField.stringValue
            AppSettings.shared.geminiAPIKey = key
            updateAPIKeyStatus(key: key)
            setAPIKeyEditing(false)
            updateDGBackendLabel()
            window?.makeFirstResponder(nil)
        } else {
            setAPIKeyEditing(true)
            window?.makeFirstResponder(apiKeyField)
        }
    }

    @objc private func apiKeySavePressed() {
        if apiKeyIsEditing { apiKeyEditPressed() }
    }

    @objc private func dgKeyEditPressed() {
        if dgKeyIsEditing {
            let key = dgKeyField.stringValue
            AppSettings.shared.deepgramAPIKey = key
            updateDGKeyStatus(key: key)
            setDGKeyEditing(false)
            updateDGBackendLabel()
            window?.makeFirstResponder(nil)
        } else {
            setDGKeyEditing(true)
            window?.makeFirstResponder(dgKeyField)
        }
    }

    @objc private func dgKeySavePressed() {
        if dgKeyIsEditing { dgKeyEditPressed() }
    }

    @objc private func openDeepgramConsole() {
        NSWorkspace.shared.open(URL(string: "https://console.deepgram.com/signup")!)
    }

    @objc private func openAIStudio() {
        NSWorkspace.shared.open(URL(string: "https://aistudio.google.com/app/apikey")!)
    }

    @objc private func silenceCheckChanged() {
        AppSettings.shared.silenceDetectionEnabled = silenceCheck.state == .on
        updateSilenceRowEnabled()
    }

    @objc private func silenceTimeoutChanged() {
        let v = max(5, min(60, silenceTimeout.integerValue))
        silenceTimeout.integerValue        = v
        silenceTimeoutStepper.integerValue = v
        AppSettings.shared.silenceTimeoutSeconds = v
    }

    @objc private func silenceStepperChanged(_ sender: NSStepper) {
        silenceTimeout.integerValue = sender.integerValue
        AppSettings.shared.silenceTimeoutSeconds = sender.integerValue
    }

    // MARK: - NSTextFieldDelegate (silence timeout + custom prompt fields)

    // Strip non-digit characters live as the user types, and sync the stepper
    // immediately so arrows always operate on the current typed value.
    // Also saves the custom prompt on every keystroke so it's available immediately.
    func controlTextDidChange(_ obj: Notification) {
        if (obj.object as? NSTextField) === ppCustomField {
            AppSettings.shared.customPostProcessingPrompt = ppCustomField.stringValue
            return
        }
        guard (obj.object as? NSTextField) === silenceTimeout else { return }
        // Remove any non-digit characters in place
        let digits = silenceTimeout.stringValue.filter { $0.isNumber }
        if digits != silenceTimeout.stringValue {
            silenceTimeout.stringValue = digits
        }
        // Sync stepper to the current raw value (no clamping yet — allow partial input)
        if let v = Int(digits) {
            silenceTimeoutStepper.integerValue = max(5, min(60, v))
        }
    }

    // Clamp and save when Return is pressed (already wired via .action → silenceTimeoutChanged).
    // Also called by controlTextDidEndEditing below.

    // Save when the field loses focus for any reason (click elsewhere, tab, window close).
    func controlTextDidEndEditing(_ obj: Notification) {
        guard (obj.object as? NSTextField) === silenceTimeout else { return }
        silenceTimeoutChanged()
    }

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

    @objc private func hotKeyChanged() {
        let idx    = hotKeyPopup.indexOfSelectedItem
        let option = HotKeyOption.allCases[idx]
        AppSettings.shared.hotKeyOption = option
        NotificationCenter.default.post(name: .hotKeyChanged, object: nil)
    }

    @objc private func clipboardCheckChanged() {
        AppSettings.shared.copyToClipboard = clipboardCheck.state == .on
    }

    @objc private func soundCheckChanged() {
        AppSettings.shared.soundFeedbackEnabled = soundCheck.state == .on
    }

    @objc private func translationCheckChanged() {
        AppSettings.shared.translationEnabled = translationCheck.state == .on
        updateTranslationRowsEnabled()
        NotificationCenter.default.post(name: .translationSettingsChanged, object: nil)
    }

    @objc private func translationSourceChanged() {
        AppSettings.shared.translationSourceLanguage = translationSourcePopup.titleOfSelectedItem ?? "Auto-detect"
    }

    @objc private func translationTargetChanged() {
        AppSettings.shared.translationTargetLanguage = translationTargetPopup.titleOfSelectedItem ?? "English"
    }

    @objc private func addFavorite() {
        guard addFavPopup.indexOfSelectedItem > 0,
              let lang = addFavPopup.titleOfSelectedItem else { return }
        var favs = AppSettings.shared.translationFavorites
        guard !favs.contains(lang), favs.count < 6 else { return }
        favs.append(lang)
        AppSettings.shared.translationFavorites = favs
        loadFavorites()
    }

    @objc private func removeFavorite(_ sender: NSButton) {
        var favs = AppSettings.shared.translationFavorites
        guard sender.tag < favs.count else { return }
        favs.remove(at: sender.tag)
        AppSettings.shared.translationFavorites = favs
        loadFavorites()
    }

    // MARK: - Show

    func showSettings() {
        installEditMenu()
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)

        if showMigrationNotice {
            migrationBanner.isHidden = false
            migrationBanner.superview?.isHidden = false
        }

        DispatchQueue.main.async { [weak self] in
            guard let self, let w = self.window else { return }
            if self.dgKeyIsEditing      { w.makeFirstResponder(self.dgKeyField) }
            else if self.apiKeyIsEditing { w.makeFirstResponder(self.apiKeyField) }
        }

        // When the user clicks anywhere in the window while the silence timeout field
        // is first responder, force it to commit before the click is processed.
        // This ensures typing a value then clicking a checkbox registers the new value.
        silenceMouseMonitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { [weak self] event in
            guard let self else { return event }
            guard let w = self.window, let fr = w.firstResponder else { return event }
            // fieldEditor is an NSTextView subclass; its delegate is the actual NSTextField
            let fieldEditor = fr as? NSTextView
            let activeField = fieldEditor?.delegate as? NSTextField ?? fr as? NSTextField
            if activeField === self.silenceTimeout {
                self.silenceTimeoutChanged()
                w.makeFirstResponder(nil)
            }
            return event
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
        if apiKeyIsEditing {
            AppSettings.shared.geminiAPIKey = apiKeyField.stringValue
        }
        if dgKeyIsEditing {
            AppSettings.shared.deepgramAPIKey = dgKeyField.stringValue
        }
        AppSettings.shared.customPostProcessingPrompt = ppCustomField.stringValue
        if let monitor = silenceMouseMonitor {
            NSEvent.removeMonitor(monitor)
            silenceMouseMonitor = nil
        }
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
        btn.title       = "Grant Access"
        btn.bezelStyle  = .rounded
        btn.controlSize = .small
        btn.target = self; btn.action = #selector(tapped)

        self.label.font = .systemFont(ofSize: 13)

        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: leadingAnchor),
            icon.centerYAnchor.constraint(equalTo: centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 16),
            icon.heightAnchor.constraint(equalToConstant: 16),

            self.label.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 8),
            self.label.centerYAnchor.constraint(equalTo: centerYAnchor),

            btn.trailingAnchor.constraint(equalTo: trailingAnchor),
            btn.centerYAnchor.constraint(equalTo: centerYAnchor),

            heightAnchor.constraint(equalToConstant: 26),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    func setGranted(_ granted: Bool, action: @escaping () -> Void) {
        grantAction = action
        let cfg = NSImage.SymbolConfiguration(pointSize: 13, weight: .regular)
        icon.image = NSImage(
            systemSymbolName: granted ? "checkmark.circle.fill" : "xmark.circle.fill",
            accessibilityDescription: nil
        )?.withSymbolConfiguration(cfg)
        icon.contentTintColor = granted ? .systemGreen : .systemRed
        btn.isHidden = granted
    }

    @objc private func tapped() { grantAction?() }
}
