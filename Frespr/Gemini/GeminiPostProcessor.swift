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

    // gemini-2.5-flash: replaces deprecated gemini-2.0-flash (shutdown June 1 2026).
    private static let endpoint =
        "https://generativelanguage.googleapis.com/v1beta/models/gemini-2.5-flash:generateContent"

    /// Apply `systemPrompt` to `rawText` and return the model's response.
    /// Throws on network error, non-200 response, or empty result.
    /// Callers should catch and fall back to `rawText`.
    ///
    /// `userMessagePrefix` — verb prefixed to "this transcript:" in the user turn (e.g. "Reformat").
    ///
    /// `inlineInstruction` — when set (custom prompt mode), the instruction is placed directly
    /// in the user message rather than as a system instruction. This ensures Gemini treats it
    /// as a direct command, not background context. systemPrompt is ignored when this is set.
    static func process(
        rawText: String,
        systemPrompt: String,
        apiKey: String,
        userMessagePrefix: String = "Process",
        inlineInstruction: String? = nil
    ) async throws -> String {
        guard let url = URL(string: endpoint) else {
            throw URLError(.badURL)
        }

        // For custom instructions: embed the instruction directly in the user message so the
        // model treats it as a direct command rather than background system context.
        // For built-in modes (cleanup/summarize): use systemInstruction as normal.
        let userMessage: String
        let sysInstruction: String
        if let inline = inlineInstruction {
            userMessage = "\(inline)\n\nHere is the transcript:\n<transcript>\n\(rawText)\n</transcript>\n\nOutput only the result, no commentary."
            sysInstruction = "You are a helpful assistant. Follow the user's instruction exactly."
        } else {
            userMessage = "\(userMessagePrefix) this transcript:\n<transcript>\n\(rawText)\n</transcript>"
            sysInstruction = systemPrompt
        }

        let body = GenerateRequest(
            systemInstruction: .init(parts: [.init(text: sysInstruction)]),
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
            dbg("GeminiPostProcessor HTTP \(http.statusCode): \(msg.prefix(400))")
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
