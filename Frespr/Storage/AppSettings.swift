import Foundation
import Observation
import Security

@Observable
final class AppSettings {
    static let shared = AppSettings()

    private let defaults = UserDefaults.standard

    var geminiAPIKey: String {
        get { KeychainHelper.read() ?? "" }
        set { KeychainHelper.write(newValue) }
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

    var copyToClipboard: Bool {
        get { defaults.bool(forKey: Keys.copyToClipboard) }
        set { defaults.set(newValue, forKey: Keys.copyToClipboard) }
    }

    var silenceDetectionEnabled: Bool {
        get { defaults.bool(forKey: Keys.silenceDetectionEnabled) }
        set { defaults.set(newValue, forKey: Keys.silenceDetectionEnabled) }
    }

    var silenceTimeoutSeconds: Int {
        get { defaults.integer(forKey: Keys.silenceTimeoutSeconds) }
        set { defaults.set(newValue, forKey: Keys.silenceTimeoutSeconds) }
    }

    var hotKeyOption: HotKeyOption {
        get {
            let raw = defaults.string(forKey: Keys.hotKeyOption) ?? HotKeyOption.rightOption.rawValue
            return HotKeyOption.from(rawValue: raw)
        }
        set { defaults.set(newValue.rawValue, forKey: Keys.hotKeyOption) }
    }

    var translationEnabled: Bool {
        get { defaults.bool(forKey: Keys.translationEnabled) }
        set { defaults.set(newValue, forKey: Keys.translationEnabled) }
    }

    var translationSourceLanguage: String {
        get { defaults.string(forKey: Keys.translationSourceLanguage) ?? "Auto-detect" }
        set { defaults.set(newValue, forKey: Keys.translationSourceLanguage) }
    }

    var translationTargetLanguage: String {
        get { defaults.string(forKey: Keys.translationTargetLanguage) ?? "English" }
        set { defaults.set(newValue, forKey: Keys.translationTargetLanguage) }
    }

    var soundFeedbackEnabled: Bool {
        get { defaults.bool(forKey: Keys.soundFeedbackEnabled) }
        set { defaults.set(newValue, forKey: Keys.soundFeedbackEnabled) }
    }

    var lastUpdateCheckDate: Date? {
        get {
            let t = defaults.double(forKey: Keys.lastUpdateCheckDate)
            return t == 0 ? nil : Date(timeIntervalSince1970: t)
        }
        set { defaults.set(newValue?.timeIntervalSince1970 ?? 0, forKey: Keys.lastUpdateCheckDate) }
    }

    var translationFavorites: [String] {
        get {
            guard let data = defaults.data(forKey: Keys.translationFavorites),
                  let arr = try? JSONDecoder().decode([String].self, from: data)
            else { return [] }
            return arr
        }
        set {
            let data = try? JSONEncoder().encode(newValue)
            defaults.set(data, forKey: Keys.translationFavorites)
        }
    }

    /// Cycle: Off → fav[0] → fav[1] → … → Off
    func cycleTranslationFavorite() {
        let favs = translationFavorites
        guard !favs.isEmpty else { return }
        if !translationEnabled {
            translationTargetLanguage = favs[0]
            translationEnabled = true
        } else if let idx = favs.firstIndex(of: translationTargetLanguage) {
            let next = idx + 1
            if next >= favs.count {
                translationEnabled = false
            } else {
                translationTargetLanguage = favs[next]
            }
        } else {
            translationTargetLanguage = favs[0]
            translationEnabled = true
        }
        NotificationCenter.default.post(name: .translationSettingsChanged, object: nil)
    }

    private init() {
        defaults.register(defaults: [
            Keys.copyToClipboard: false,
            Keys.silenceDetectionEnabled: true,
            Keys.silenceTimeoutSeconds: 10,
            Keys.hotKeyOption: HotKeyOption.rightOption.rawValue,
            Keys.postProcessingMode: PostProcessingMode.cleanup.rawValue,
            Keys.soundFeedbackEnabled: true,
            Keys.translationEnabled: false,
            Keys.translationSourceLanguage: "Auto-detect",
            Keys.translationTargetLanguage: "English"
        ])
        // Migrate legacy API key from UserDefaults → Keychain (one-time)
        if let legacy = defaults.string(forKey: Keys.geminiAPIKey), !legacy.isEmpty {
            KeychainHelper.write(legacy)
            defaults.removeObject(forKey: Keys.geminiAPIKey)
        }
    }

    private enum Keys {
        static let geminiAPIKey              = "geminiAPIKey"
        static let postProcessingMode        = "postProcessingMode"
        static let customPostProcessingPrompt = "customPostProcessingPrompt"
        static let copyToClipboard           = "copyToClipboard"
        static let silenceDetectionEnabled   = "silenceDetectionEnabled"
        static let silenceTimeoutSeconds     = "silenceTimeoutSeconds"
        static let hotKeyOption              = "hotKeyOption"
        static let translationEnabled        = "translationEnabled"
        static let translationSourceLanguage = "translationSourceLanguage"
        static let translationTargetLanguage = "translationTargetLanguage"
        static let translationFavorites      = "translationFavorites"
        static let soundFeedbackEnabled      = "soundFeedbackEnabled"
        static let lastUpdateCheckDate       = "lastUpdateCheckDate"
    }
}

// MARK: - Supported translation languages

let kSupportedLanguages: [String] = [
    "Afrikaans", "Albanian", "Amharic", "Arabic", "Armenian", "Azerbaijani",
    "Basque", "Belarusian", "Bengali", "Bosnian", "Bulgarian",
    "Catalan", "Cebuano", "Chinese (Simplified)", "Chinese (Traditional)",
    "Corsican", "Croatian", "Czech",
    "Danish", "Dutch",
    "English", "Esperanto", "Estonian",
    "Finnish", "French", "Frisian",
    "Galician", "Georgian", "German", "Greek", "Gujarati",
    "Haitian Creole", "Hausa", "Hawaiian", "Hebrew", "Hindi", "Hmong", "Hungarian",
    "Icelandic", "Igbo", "Indonesian", "Irish", "Italian",
    "Japanese", "Javanese",
    "Kannada", "Kazakh", "Khmer", "Kinyarwanda", "Korean", "Kurdish", "Kyrgyz",
    "Lao", "Latin", "Latvian", "Lithuanian", "Luxembourgish",
    "Macedonian", "Malagasy", "Malay", "Malayalam", "Maltese", "Maori", "Marathi",
    "Mongolian", "Myanmar (Burmese)",
    "Nepali", "Norwegian",
    "Nyanja (Chichewa)",
    "Odia (Oriya)",
    "Pashto", "Persian", "Polish", "Portuguese", "Punjabi",
    "Romanian", "Russian",
    "Samoan", "Scots Gaelic", "Serbian", "Sesotho", "Shona", "Sindhi",
    "Sinhala (Sinhalese)", "Slovak", "Slovenian", "Somali", "Spanish",
    "Sundanese", "Swahili", "Swedish",
    "Tagalog (Filipino)", "Tajik", "Tamil", "Tatar", "Telugu", "Thai",
    "Turkish", "Turkmen",
    "Ukrainian", "Urdu", "Uyghur", "Uzbek",
    "Vietnamese",
    "Welsh",
    "Xhosa",
    "Yiddish", "Yoruba",
    "Zulu"
]

// MARK: - KeychainHelper

private enum KeychainHelper {
    private static let service = "com.frespr.app"
    private static let account = "geminiAPIKey"

    static func read() -> String? {
        let query: [CFString: Any] = [
            kSecClass:            kSecClassGenericPassword,
            kSecAttrService:      service,
            kSecAttrAccount:      account,
            kSecReturnData:       true,
            kSecMatchLimit:       kSecMatchLimitOne
        ]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess,
              let data = result as? Data,
              let str = String(data: data, encoding: .utf8) else { return nil }
        return str
    }

    static func write(_ value: String) {
        guard let data = value.data(using: .utf8) else { return }
        if read() != nil {
            let query: [CFString: Any] = [
                kSecClass:       kSecClassGenericPassword,
                kSecAttrService: service,
                kSecAttrAccount: account
            ]
            let attrs: [CFString: Any] = [kSecValueData: data]
            SecItemUpdate(query as CFDictionary, attrs as CFDictionary)
        } else {
            let item: [CFString: Any] = [
                kSecClass:       kSecClassGenericPassword,
                kSecAttrService: service,
                kSecAttrAccount: account,
                kSecValueData:   data
            ]
            SecItemAdd(item as CFDictionary, nil)
        }
    }

    static func delete() {
        let query: [CFString: Any] = [
            kSecClass:       kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account
        ]
        SecItemDelete(query as CFDictionary)
    }
}

enum PostProcessingMode: String, CaseIterable {
    case none      = "none"
    case cleanup   = "cleanup"
    case summarize = "summarize"
    case custom    = "custom"

    var shortLabel: String {
        switch self {
        case .none:      return "None"
        case .cleanup:   return "Clean up"
        case .summarize: return "Summarize"
        case .custom:    return "Custom"
        }
    }

    var next: PostProcessingMode {
        let all = PostProcessingMode.allCases
        let idx = all.firstIndex(of: self) ?? 0
        return all[(idx + 1) % all.count]
    }

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
