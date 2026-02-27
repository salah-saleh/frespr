import AppKit

/// The set of supported push-to-talk hotkeys.
enum HotKeyOption: String, CaseIterable {
    case rightOption   = "rightOption"    // default
    case leftOption    = "leftOption"
    case fn            = "fn"
    case rightCommand  = "rightCommand"
    case ctrlOption    = "ctrlOption"

    var label: String {
        switch self {
        case .rightOption:  return "Right ⌥"
        case .leftOption:   return "Left ⌥"
        case .fn:           return "Fn / Globe"
        case .rightCommand: return "Right ⌘"
        case .ctrlOption:   return "^ ⌥ (Ctrl+Option)"
        }
    }

    static func from(rawValue: String) -> HotKeyOption {
        return HotKeyOption(rawValue: rawValue) ?? .rightOption
    }
}

extension Notification.Name {
    static let hotKeyChanged         = Notification.Name("FresprHotKeyChanged")
    static let translationSettingsChanged = Notification.Name("FresprTranslationSettingsChanged")
}
