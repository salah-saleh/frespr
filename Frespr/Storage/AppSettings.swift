import Foundation
import Observation

@Observable
final class AppSettings {
    static let shared = AppSettings()

    private let defaults = UserDefaults.standard

    var geminiAPIKey: String {
        get { defaults.string(forKey: Keys.geminiAPIKey) ?? "" }
        set { defaults.set(newValue, forKey: Keys.geminiAPIKey) }
    }

    var hotkeyMode: HotkeyMode {
        get {
            let raw = defaults.string(forKey: Keys.hotkeyMode) ?? HotkeyMode.hold.rawValue
            return HotkeyMode(rawValue: raw) ?? .hold
        }
        set { defaults.set(newValue.rawValue, forKey: Keys.hotkeyMode) }
    }

    var showOverlay: Bool {
        get { defaults.bool(forKey: Keys.showOverlay) }
        set { defaults.set(newValue, forKey: Keys.showOverlay) }
    }

    private init() {
        // Register defaults
        defaults.register(defaults: [
            Keys.hotkeyMode: HotkeyMode.hold.rawValue,
            Keys.showOverlay: true
        ])
    }

    private enum Keys {
        static let geminiAPIKey = "geminiAPIKey"
        static let hotkeyMode = "hotkeyMode"
        static let showOverlay = "showOverlay"
    }
}

enum HotkeyMode: String, CaseIterable {
    case hold = "hold"
    case toggle = "toggle"

    var displayName: String {
        switch self {
        case .hold: return "Hold (push-to-talk)"
        case .toggle: return "Toggle (tap to start/stop)"
        }
    }
}
