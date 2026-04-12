import Foundation

// MARK: - TranscriptionError

enum TranscriptionError: Error {
    case connectionFailed(String)
    case unauthorized
}

// MARK: - TranscriptionBackend

/// Common interface for transcription backends (Deepgram, Gemini Live, etc.)
@MainActor
protocol TranscriptionBackend: AnyObject {

    // MARK: Callbacks

    var onTranscriptUpdate: ((String, Bool) -> Void)? { get set }
    var onError: ((Error) -> Void)? { get set }
    var onDisconnected: (() -> Void)? { get set }
    var onSetupComplete: (() -> Void)? { get set }

    // MARK: State

    var currentPartialTranscript: String { get }

    // MARK: Lifecycle

    func connect(apiKey: String) async throws
    func sendAudioChunk(data: Data)
    func sendStreamEnd()
    func disconnect()

    // MARK: Activity markers (Gemini-specific; no-op on Deepgram)

    func sendActivityStart()
    func sendActivityBounce()
}
