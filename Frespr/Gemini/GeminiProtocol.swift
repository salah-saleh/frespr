import Foundation

// MARK: - Outbound (Client → Server)

struct GeminiSetupMessage: Encodable {
    let setup: Setup

    struct Setup: Encodable {
        let model: String
        let generationConfig: GenerationConfig
        let inputAudioTranscription: InputAudioTranscription
        let systemInstruction: SystemInstruction?
        let realtimeInputConfig: RealtimeInputConfig?

        struct GenerationConfig: Encodable {
            let responseModalities: [String]
            let contextWindowCompression: ContextWindowCompression?

            struct ContextWindowCompression: Encodable {
                let slidingWindow: SlidingWindow
                struct SlidingWindow: Encodable {}
            }

            enum CodingKeys: String, CodingKey {
                case responseModalities, contextWindowCompression
            }
            func encode(to encoder: Encoder) throws {
                var container = encoder.container(keyedBy: CodingKeys.self)
                try container.encode(responseModalities, forKey: .responseModalities)
                if let cwc = contextWindowCompression { try container.encode(cwc, forKey: .contextWindowCompression) }
            }
        }

        // Empty object enables transcription
        struct InputAudioTranscription: Encodable {}

        struct SystemInstruction: Encodable {
            let parts: [Part]
            struct Part: Encodable {
                let text: String
            }
        }

        struct RealtimeInputConfig: Encodable {
            let automaticActivityDetection: AutomaticActivityDetection?
            let proactiveAudio: Bool?

            struct AutomaticActivityDetection: Encodable {
                let disabled: Bool?
            }

            enum CodingKeys: String, CodingKey {
                case automaticActivityDetection, proactiveAudio
            }
            func encode(to encoder: Encoder) throws {
                var container = encoder.container(keyedBy: CodingKeys.self)
                if let aad = automaticActivityDetection { try container.encode(aad, forKey: .automaticActivityDetection) }
                if let pa = proactiveAudio { try container.encode(pa, forKey: .proactiveAudio) }
            }
        }

        // Custom encoding: omit nil fields so the server doesn't reject unknown empty objects
        enum CodingKeys: String, CodingKey {
            case model, generationConfig, inputAudioTranscription
            case systemInstruction, realtimeInputConfig
        }

        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(model, forKey: .model)
            try container.encode(generationConfig, forKey: .generationConfig)
            try container.encode(inputAudioTranscription, forKey: .inputAudioTranscription)
            if let si = systemInstruction { try container.encode(si, forKey: .systemInstruction) }
            if let ric = realtimeInputConfig { try container.encode(ric, forKey: .realtimeInputConfig) }
        }
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

/// Manual activity markers for when VAD is disabled.
struct GeminiActivityMessage: Encodable {
    let realtimeInput: Activity

    struct Activity: Encodable {
        let activityStart: EmptyObject?
        let activityEnd: EmptyObject?

        struct EmptyObject: Encodable {}

        enum CodingKeys: String, CodingKey {
            case activityStart, activityEnd
        }
        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            if let a = activityStart { try container.encode(a, forKey: .activityStart) }
            if let a = activityEnd { try container.encode(a, forKey: .activityEnd) }
        }
    }

    static var start: GeminiActivityMessage {
        GeminiActivityMessage(realtimeInput: Activity(
            activityStart: Activity.EmptyObject(), activityEnd: nil))
    }
    static var end: GeminiActivityMessage {
        GeminiActivityMessage(realtimeInput: Activity(
            activityStart: nil, activityEnd: Activity.EmptyObject()))
    }
}

// MARK: - Inbound (Server → Client)

struct GeminiServerMessage: Decodable {
    let setupComplete: SetupComplete?
    let serverContent: ServerContent?
    let goAway: GoAway?

    struct SetupComplete: Decodable {}
    struct GoAway: Decodable {}

    struct ServerContent: Decodable {
        let inputTranscription: InputTranscription?
        let outputTranscription: OutputTranscription?
        let modelTurn: ModelTurn?
        let turnComplete: Bool?
        let generationComplete: Bool?  // also signals end of turn for native audio model

        struct InputTranscription: Decodable {
            let text: String?
            let finished: Bool?
        }

        struct OutputTranscription: Decodable {
            let text: String?
        }

        // Model audio/text responses — decoded but ignored for transcription-only use
        struct ModelTurn: Decodable {
            // Accept any JSON structure without parsing details
            init(from decoder: Decoder) throws {}
        }
    }
}

// MARK: - Helpers

extension GeminiSetupMessage {
    static func make(model: String = "models/gemini-2.5-flash-native-audio-preview-12-2025") -> GeminiSetupMessage {
        GeminiSetupMessage(setup: Setup(
            model: model,
            // Native audio model requires AUDIO modality (TEXT alone causes 1007 rejection).
            generationConfig: Setup.GenerationConfig(
                responseModalities: ["AUDIO"],
                contextWindowCompression: nil
            ),
            inputAudioTranscription: Setup.InputAudioTranscription(),
            systemInstruction: nil,
            // Disable automatic VAD so the server never fires turnComplete mid-recording.
            // We control the turn boundary ourselves via activityStart/activityEnd.
            realtimeInputConfig: Setup.RealtimeInputConfig(
                automaticActivityDetection: Setup.RealtimeInputConfig.AutomaticActivityDetection(disabled: true),
                proactiveAudio: nil
            )
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
