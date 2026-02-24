import Foundation
import Observation

struct TranscriptionEntry: Codable {
    let id: UUID
    let text: String
    let timestamp: Date
}

@Observable
final class TranscriptionLog {
    static let shared = TranscriptionLog()
    static let maxEntries = 20
    private let defaults = UserDefaults.standard
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()
    private enum Keys { static let entries = "transcriptionLogEntries" }

    private(set) var entries: [TranscriptionEntry] = []  // oldest first, newest last

    private init() {
        if let data = defaults.data(forKey: Keys.entries),
           let decoded = try? decoder.decode([TranscriptionEntry].self, from: data) {
            entries = decoded
        }
    }

    func add(text: String) {
        entries.append(TranscriptionEntry(id: UUID(), text: text, timestamp: Date()))
        if entries.count > Self.maxEntries {
            entries.removeFirst(entries.count - Self.maxEntries)
        }
        persist()
    }

    func clear() {
        entries.removeAll()
        persist()
    }

    private func persist() {
        if let data = try? encoder.encode(entries) {
            defaults.set(data, forKey: Keys.entries)
        }
    }
}
