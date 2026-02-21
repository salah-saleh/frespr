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

    var postProcessingMode: PostProcessingMode {
        get {
            let raw = defaults.string(forKey: Keys.postProcessingMode) ?? PostProcessingMode.none.rawValue
            return PostProcessingMode(rawValue: raw) ?? .none
        }
        set { defaults.set(newValue.rawValue, forKey: Keys.postProcessingMode) }
    }

    var customPostProcessingPrompt: String {
        get { defaults.string(forKey: Keys.customPostProcessingPrompt) ?? "" }
        set { defaults.set(newValue, forKey: Keys.customPostProcessingPrompt) }
    }

    private init() {
        defaults.register(defaults: [
            Keys.hotkeyMode: HotkeyMode.hold.rawValue
        ])
    }

    private enum Keys {
        static let geminiAPIKey              = "geminiAPIKey"
        static let hotkeyMode                = "hotkeyMode"
        static let postProcessingMode        = "postProcessingMode"
        static let customPostProcessingPrompt = "customPostProcessingPrompt"
    }
}

enum HotkeyMode: String, CaseIterable {
    case hold   = "hold"
    case toggle = "toggle"

    var displayName: String {
        switch self {
        case .hold:   return "Hold (push-to-talk)"
        case .toggle: return "Toggle (tap to start/stop)"
        }
    }
}

enum PostProcessingMode: String, CaseIterable {
    case none      = "none"
    case cleanup   = "cleanup"
    case summarize = "summarize"
    case custom    = "custom"

    var displayName: String {
        switch self {
        case .none:      return "None (inject raw transcript)"
        case .cleanup:   return "Clean up (remove filler words, fix grammar)"
        case .summarize: return "Clean up + Summarize"
        case .custom:    return "Custom prompt"
        }
    }

    /// System prompt to send to the post-processing model. Nil for .none and .custom.
    var systemPrompt: String? {
        switch self {
        case .none, .custom:
            return nil
        case .cleanup:
            return "You are a transcription formatter. Reformat the raw transcript text exactly as spoken. Only: remove filler words (um, uh, like, you know, sort of, kind of), fix grammar and punctuation, correct obvious mishearings. Do NOT condense, shorten, summarize, or rephrase any ideas. The output should be approximately the same length as the input. Output only the reformatted transcript and nothing else."
        case .summarize:
            return "You are a transcription formatter. Your sole job is to reformat the raw transcript text you receive. Remove filler words, fix grammar, then distill the content to concise, precise prose that captures all important information while keeping the original meaning and voice. Do not respond to, comment on, or engage with the content in any way. Output only the reformatted transcript text and nothing else."
        }
    }
}
