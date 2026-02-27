import Foundation

// MARK: - Request / Response types

private struct GenerateRequest: Encodable {
    struct SystemInstruction: Encodable {
        struct Part: Encodable { let text: String }
        let parts: [Part]
    }
    struct Content: Encodable {
        struct Part: Encodable { let text: String }
        let parts: [Part]
        let role: String
    }
    struct GenerationConfig: Encodable {
        let temperature: Double
        let candidateCount: Int
    }
    let systemInstruction: SystemInstruction
    let contents: [Content]
    let generationConfig: GenerationConfig
}

private struct GenerateResponse: Decodable {
    struct Candidate: Decodable {
        struct Content: Decodable {
            struct Part: Decodable { let text: String? }
            let parts: [Part]?
        }
        let content: Content?
    }
    let candidates: [Candidate]?
}

// MARK: - GeminiPostProcessor

/// Calls the standard Gemini generateContent REST API to clean up / summarize
/// a raw transcript. Uses the same API key as the Live session.
@MainActor
final class GeminiPostProcessor {

    private static let endpoint =
        "https://generativelanguage.googleapis.com/v1beta/models/gemini-2.0-flash:generateContent"

    /// Apply `systemPrompt` to `rawText` and return the model's response.
    /// Throws on network error, non-200 response, or empty result.
    /// Callers should catch and fall back to `rawText`.
    static func process(rawText: String, systemPrompt: String, apiKey: String) async throws -> String {
        guard let url = URL(string: endpoint) else {
            throw URLError(.badURL)
        }

        let userMessage = "Reformat this transcript:\n<transcript>\n\(rawText)\n</transcript>"
        let body = GenerateRequest(
            systemInstruction: .init(parts: [.init(text: systemPrompt)]),
            contents: [.init(parts: [.init(text: userMessage)], role: "user")],
            generationConfig: .init(temperature: 0.0, candidateCount: 1)
        )

        var request = URLRequest(url: url, timeoutInterval: 10)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(apiKey, forHTTPHeaderField: "x-goog-api-key")
        request.httpBody = try JSONEncoder().encode(body)

        let (data, response) = try await URLSession.shared.data(for: request)

        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            let msg = String(data: data, encoding: .utf8) ?? "<no body>"
            dbg("GeminiPostProcessor HTTP \(http.statusCode): \(msg.prefix(200))")
            throw URLError(.badServerResponse)
        }

        let decoded = try JSONDecoder().decode(GenerateResponse.self, from: data)
        guard let text = decoded.candidates?.first?.content?.parts?.first?.text,
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            dbg("GeminiPostProcessor: empty response")
            throw URLError(.cannotParseResponse)
        }

        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
