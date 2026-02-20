import Foundation

// MARK: - Outbound (Client → Server)

struct GeminiSetupMessage: Encodable {
    let setup: Setup

    struct Setup: Encodable {
        let model: String
        let generationConfig: GenerationConfig
        let inputAudioTranscription: InputAudioTranscription

        struct GenerationConfig: Encodable {
            let responseModalities: [String]
        }

        // Empty object enables transcription
        struct InputAudioTranscription: Encodable {}
    }
}

struct GeminiRealtimeInputMessage: Encodable {
    let realtimeInput: RealtimeInput

    struct RealtimeInput: Encodable {
        let audio: AudioChunk?
        let audioStreamEnd: Bool?

        struct AudioChunk: Encodable {
            let data: String      // base64-encoded PCM
            let mimeType: String  // required: "audio/pcm;rate=16000"
        }

        // Custom encoding to omit nil fields
        enum CodingKeys: String, CodingKey {
            case audio, audioStreamEnd
        }

        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            if let audio = audio {
                try container.encode(audio, forKey: .audio)
            }
            if let audioStreamEnd = audioStreamEnd {
                try container.encode(audioStreamEnd, forKey: .audioStreamEnd)
            }
        }
    }
}

// MARK: - Inbound (Server → Client)

struct GeminiServerMessage: Decodable {
    let setupComplete: SetupComplete?
    let serverContent: ServerContent?

    struct SetupComplete: Decodable {}

    struct ServerContent: Decodable {
        let inputTranscription: InputTranscription?
        let outputTranscription: OutputTranscription?
        let turnComplete: Bool?
        let generationComplete: Bool?  // also signals end of turn for native audio model

        struct InputTranscription: Decodable {
            let text: String?
            let finished: Bool?
        }

        struct OutputTranscription: Decodable {
            let text: String?
        }
    }
}

// MARK: - Helpers

extension GeminiSetupMessage {
    static func make(model: String = "models/gemini-2.5-flash-native-audio-preview-12-2025") -> GeminiSetupMessage {
        GeminiSetupMessage(setup: Setup(
            model: model,
            // Native audio model requires AUDIO modality (TEXT alone causes close 1007)
            generationConfig: Setup.GenerationConfig(responseModalities: ["AUDIO"]),
            inputAudioTranscription: Setup.InputAudioTranscription()
        ))
    }
}

extension GeminiRealtimeInputMessage {
    static func audioChunk(base64: String) -> GeminiRealtimeInputMessage {
        GeminiRealtimeInputMessage(realtimeInput: RealtimeInput(
            audio: RealtimeInput.AudioChunk(data: base64, mimeType: "audio/pcm;rate=16000"),
            audioStreamEnd: nil
        ))
    }

    static var streamEnd: GeminiRealtimeInputMessage {
        GeminiRealtimeInputMessage(realtimeInput: RealtimeInput(
            audio: nil,
            audioStreamEnd: true
        ))
    }
}
