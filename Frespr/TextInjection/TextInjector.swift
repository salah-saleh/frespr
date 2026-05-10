import ApplicationServices
import AppKit
import Carbon
import Foundation

@MainActor
final class TextInjector {
    static let shared = TextInjector()
    private init() {}

    func inject(text: String) {
        guard !text.isEmpty else { return }
        let text = text.hasSuffix(" ") ? text : text + " "
        dbg("inject: '\(text.prefix(80))'")

        if tryAXInjection(text: text) {
            dbg("inject: AX succeeded")
            return
        }
        dbg("inject: AX failed/skipped, using pasteboard fallback")
        pasteboardFallback(text: text)
    }

    // MARK: - AXUIElement Injection

    // Apps where the AX value attribute either isn't settable or setting it
    // corrupts the underlying editor (WebKit/stream-based views). Skip AX and
    // go straight to the pasteboard fallback.
    private static let axDenylistBundleIDs: Set<String> = [
        "com.apple.Terminal",
        "com.googlecode.iterm2",
        "com.apple.mail",
        "com.microsoft.VSCode",
        "com.todesktop.230313mzl4w4u92",  // Cursor
        "com.google.Chrome",
        "com.apple.Safari",
        "com.brave.Browser",
        "com.microsoft.edgemac",
        "org.mozilla.firefox",
        "com.tinyspeck.slackmacgap",
        "com.hnc.Discord",
    ]

    private func tryAXInjection(text: String) -> Bool {
        if let frontBundleID = NSWorkspace.shared.frontmostApplication?.bundleIdentifier,
           Self.axDenylistBundleIDs.contains(frontBundleID) {
            dbg("AX: skipping for \(frontBundleID) (denylisted)")
            return false
        }

        let systemElement = AXUIElementCreateSystemWide()

        var focusedElement: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(
            systemElement,
            kAXFocusedUIElementAttribute as CFString,
            &focusedElement
        )
        guard result == .success, let element = focusedElement else {
            dbg("AX: no focused element (result=\(result.rawValue))")
            return false
        }

        let axElement = element as! AXUIElement

        // Only inject into roles we know are safe (plain text fields/areas).
        // AXWebArea and custom roles tend to either silently fail or corrupt
        // their backing model when kAXValueAttribute is set.
        var roleValue: CFTypeRef?
        AXUIElementCopyAttributeValue(axElement, kAXRoleAttribute as CFString, &roleValue)
        let role = (roleValue as? String) ?? ""
        let safeRoles: Set<String> = [
            kAXTextFieldRole as String,
            kAXTextAreaRole as String,
            kAXComboBoxRole as String,
        ]
        guard safeRoles.contains(role) else {
            dbg("AX: role '\(role)' not in safe list")
            return false
        }

        // Check if element is settable
        var settable: DarwinBoolean = false
        AXUIElementIsAttributeSettable(axElement, kAXValueAttribute as CFString, &settable)
        guard settable.boolValue else {
            dbg("AX: element not settable")
            return false
        }

        // Get current value
        var currentValue: CFTypeRef?
        AXUIElementCopyAttributeValue(axElement, kAXValueAttribute as CFString, &currentValue)
        let currentText = (currentValue as? String) ?? ""

        // Get selected range (cursor position). AX ranges are in UTF-16 units,
        // so operate on NSString to avoid grapheme-vs-codepoint mismatches.
        var selectedRangeValue: CFTypeRef?
        AXUIElementCopyAttributeValue(axElement, kAXSelectedTextRangeAttribute as CFString, &selectedRangeValue)

        let nsCurrent = currentText as NSString
        if let rangeValue = selectedRangeValue {
            var cfRange = CFRange()
            if AXValueGetValue(rangeValue as! AXValue, AXValueType.cfRange, &cfRange) {
                let start = max(0, min(cfRange.location, nsCurrent.length))
                let end = max(start, min(cfRange.location + cfRange.length, nsCurrent.length))
                let mutable = NSMutableString(string: nsCurrent)
                mutable.replaceCharacters(in: NSRange(location: start, length: end - start), with: text)
                let setResult = AXUIElementSetAttributeValue(
                    axElement,
                    kAXValueAttribute as CFString,
                    mutable as CFTypeRef
                )
                if setResult == .success {
                    let nsText = text as NSString
                    let newPosition = start + nsText.length
                    var newRange = CFRange(location: newPosition, length: 0)
                    if let newRangeValue = AXValueCreate(AXValueType.cfRange, &newRange) {
                        AXUIElementSetAttributeValue(axElement, kAXSelectedTextRangeAttribute as CFString, newRangeValue)
                    }
                    return true
                }
                return false
            }
        }

        // Fallback: append to existing text
        let newText = currentText + text
        let setResult = AXUIElementSetAttributeValue(
            axElement,
            kAXValueAttribute as CFString,
            newText as CFTypeRef
        )
        return setResult == .success
    }

    // MARK: - Pasteboard Fallback

    private func pasteboardFallback(text: String) {
        dbg("pasteboardFallback: '\(text.prefix(80))'")

        guard AXIsProcessTrusted() else {
            dbg("pasteboardFallback: Accessibility not trusted — cannot synthesize Cmd+V")
            return
        }

        let pasteboard = NSPasteboard.general
        let previousContents = pasteboard.string(forType: .string)

        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        // Mark our write so well-behaved clipboard managers ignore it.
        if let bundleID = Bundle.main.bundleIdentifier {
            pasteboard.setString(bundleID, forType: NSPasteboard.PasteboardType("org.nspasteboard.source"))
        }
        pasteboard.setData(Data(), forType: NSPasteboard.PasteboardType("org.nspasteboard.TransientType"))

        let changeCountAfterWrite = pasteboard.changeCount

        // Give the pasteboard a tick to become globally visible before posting Cmd+V.
        // Without this, some apps (Terminal, sandboxed apps) read stale pasteboard
        // contents and the synthetic paste no-ops.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            simulateCmdV()
        }

        // Restore clipboard after paste completes; only if no other app has
        // written to the pasteboard since us (prevents clobbering a user paste).
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            guard pasteboard.changeCount == changeCountAfterWrite else { return }
            pasteboard.clearContents()
            if let prev = previousContents {
                pasteboard.setString(prev, forType: .string)
            }
        }
    }
}

// Posts ⌘V using a private CGEventSource so synthetic events don't combine
// with the user's real modifier state (e.g. a still-pressed hotkey), and
// posts explicit Command down/up bracketing the V key — apps like Terminal
// and Mail rely on the full modifier sequence, not just the flags bitmask.
//
// virtualKey constants: 0x37 = Command, 0x09 = V.
private func simulateCmdV() {
    let source = CGEventSource(stateID: .privateState)

    let cmdDown = CGEvent(keyboardEventSource: source, virtualKey: 0x37, keyDown: true)
    let vDown   = CGEvent(keyboardEventSource: source, virtualKey: 0x09, keyDown: true)
    let vUp     = CGEvent(keyboardEventSource: source, virtualKey: 0x09, keyDown: false)
    let cmdUp   = CGEvent(keyboardEventSource: source, virtualKey: 0x37, keyDown: false)

    cmdDown?.flags = .maskCommand
    vDown?.flags   = .maskCommand
    vUp?.flags     = .maskCommand
    // cmdUp intentionally has no flags — releasing Command.

    cmdDown?.post(tap: .cghidEventTap)
    vDown?.post(tap: .cghidEventTap)
    vUp?.post(tap: .cghidEventTap)
    cmdUp?.post(tap: .cghidEventTap)
}
