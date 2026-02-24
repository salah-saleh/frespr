import ApplicationServices
import AppKit
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
        dbg("inject: AX failed, trying pasteboard fallback")
        pasteboardFallback(text: text)
    }

    // MARK: - AXUIElement Injection

    private func tryAXInjection(text: String) -> Bool {
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

        // Get selected range (cursor position)
        var selectedRangeValue: CFTypeRef?
        AXUIElementCopyAttributeValue(axElement, kAXSelectedTextRangeAttribute as CFString, &selectedRangeValue)

        if let rangeValue = selectedRangeValue {
            var cfRange = CFRange()
            if AXValueGetValue(rangeValue as! AXValue, AXValueType.cfRange, &cfRange) {
                // Insert at cursor (replace selection with text)
                let start = min(cfRange.location, currentText.count)
                let end = min(start + cfRange.length, currentText.count)
                let startIndex = currentText.index(currentText.startIndex, offsetBy: start)
                let endIndex = currentText.index(currentText.startIndex, offsetBy: end)
                var newText = currentText
                newText.replaceSubrange(startIndex..<endIndex, with: text)
                let setResult = AXUIElementSetAttributeValue(
                    axElement,
                    kAXValueAttribute as CFString,
                    newText as CFTypeRef
                )
                if setResult == .success {
                    // Move cursor to end of inserted text
                    let newPosition = start + text.count
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

        let pasteboard = NSPasteboard.general
        let previousContents = pasteboard.string(forType: .string)

        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)

        // Simulate Cmd+V
        simulateCmdV()

        // Restore clipboard after a short delay
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            pasteboard.clearContents()
            if let prev = previousContents {
                pasteboard.setString(prev, forType: .string)
            }
        }
    }

    private func simulateCmdV() {
        let source = CGEventSource(stateID: .hidSystemState)
        let keyDown = CGEvent(keyboardEventSource: source, virtualKey: 0x09, keyDown: true)
        let keyUp = CGEvent(keyboardEventSource: source, virtualKey: 0x09, keyDown: false)
        keyDown?.flags = .maskCommand
        keyUp?.flags = .maskCommand
        keyDown?.post(tap: .cghidEventTap)
        keyUp?.post(tap: .cghidEventTap)
    }
}
