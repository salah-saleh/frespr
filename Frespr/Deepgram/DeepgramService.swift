import Foundation

// MARK: - DeepgramError

enum DeepgramError: Error, LocalizedError {
    case unauthorized
    case connectionFailed(String)

    var errorDescription: String? {
        switch self {
        case .unauthorized:
            return "Deepgram API key is invalid or unauthorized (401)."
        case .connectionFailed(let msg):
            return "Deepgram connection failed: \(msg)"
        }
    }
}

// MARK: - Deepgram JSON types

private struct DeepgramResponse: Decodable {
    struct Channel: Decodable {
        struct Alternative: Decodable {
            let transcript: String
        }
        let alternatives: [Alternative]
    }
    let channel: Channel?
    let is_final: Bool?
}

// MARK: - DeepgramService

@MainActor
final class DeepgramService: NSObject, TranscriptionBackend {

    // MARK: TranscriptionBackend callbacks

    var onTranscriptUpdate: ((String, Bool) -> Void)?
    var onError: ((Error) -> Void)?
    var onDisconnected: (() -> Void)?
    var onSetupComplete: (() -> Void)?

    // MARK: TranscriptionBackend state

    private(set) var currentPartialTranscript: String = ""

    // MARK: Private state

    private var webSocketTask: URLSessionWebSocketTask?
    private var session: URLSession?
    private var connectContinuation: CheckedContinuation<Void, Error>?

    // MARK: - connect

    func connect(apiKey: String) async throws {
        guard !apiKey.isEmpty else {
            throw DeepgramError.connectionFailed("API key is empty")
        }

        var components = URLComponents()
        components.scheme = "wss"
        components.host = "api.deepgram.com"
        components.path = "/v1/listen"
        components.queryItems = [
            URLQueryItem(name: "model", value: "nova-3"),
            URLQueryItem(name: "encoding", value: "linear16"),
            URLQueryItem(name: "sample_rate", value: "16000"),
            URLQueryItem(name: "interim_results", value: "true"),
            URLQueryItem(name: "punctuate", value: "true")
        ]
        guard let url = components.url else {
            throw DeepgramError.connectionFailed("Failed to build Deepgram URL")
        }

        var request = URLRequest(url: url)
        request.setValue("Token \(apiKey)", forHTTPHeaderField: "Authorization")

        let session = URLSession(configuration: .default, delegate: self, delegateQueue: nil)
        self.session = session
        let task = session.webSocketTask(with: request)
        self.webSocketTask = task

        dbg("[Deepgram] connecting to \(url)")

        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            self.connectContinuation = cont
            task.resume()
        }

        // Continuation was resumed by urlSession(_:webSocketTask:didOpenWithProtocol:)
        // Start receiving and notify setup complete from here (not from the delegate).
        startReceiveLoop()
        onSetupComplete?()
        dbg("[Deepgram] connected and setup complete")
    }

    // MARK: - URLSessionWebSocketDelegate (open)

    // MARK: - Receive loop

    private func startReceiveLoop() {
        guard let task = webSocketTask else { return }
        task.receive { [weak self] result in
            Task { @MainActor [weak self] in
                guard let self else { return }
                switch result {
                case .success(let message):
                    switch message {
                    case .string(let text):
                        self.handleMessage(text)
                    case .data(let data):
                        if let text = String(data: data, encoding: .utf8) {
                            self.handleMessage(text)
                        }
                    @unknown default:
                        break
                    }
                    // Re-arm
                    self.startReceiveLoop()
                case .failure(let error):
                    // A normal close (e.g. after CloseStream or disconnect()) arrives as
                    // NSPOSIXErrorDomain code 57 "Socket is not connected" or a cancelled
                    // error. These are expected and should NOT be reported as errors —
                    // just signal disconnection so the coordinator can deliver the transcript.
                    let nsError = error as NSError
                    let isNormalClose = nsError.domain == NSPOSIXErrorDomain
                        || nsError.code == NSURLErrorCancelled
                        || nsError.domain == "NSURLErrorDomain"
                    if isNormalClose {
                        dbg("[Deepgram] receive loop closed (normal) — signalling disconnect")
                    } else {
                        dbg("[Deepgram] receive error: \(error)")
                        self.onError?(error)
                    }
                    self.onDisconnected?()
                }
            }
        }
    }

    // MARK: - Handle message

    /// Internal (not private) for test visibility.
    func handleMessage(_ json: String) {
        guard let data = json.data(using: .utf8),
              let response = try? JSONDecoder().decode(DeepgramResponse.self, from: data)
        else {
            dbg("[Deepgram] handleMessage: failed to decode JSON")
            return
        }

        let text = response.channel?.alternatives.first?.transcript ?? ""
        guard !text.isEmpty else { return }

        let isFinal = response.is_final ?? false
        if isFinal {
            // Final transcript has been delivered to the coordinator via onTranscriptUpdate.
            // Clear currentPartialTranscript so the 4s poll in stopRecording() doesn't
            // re-append it and cause duplicated words at the end of the transcription.
            currentPartialTranscript = ""
        } else {
            currentPartialTranscript = text
        }
        onTranscriptUpdate?(text, isFinal)
    }

    // MARK: - sendAudioChunk

    func sendAudioChunk(data: Data) {
        webSocketTask?.send(.data(data)) { error in
            if let error {
                dbg("[Deepgram] sendAudioChunk error: \(error)")
            }
        }
    }

    // MARK: - sendStreamEnd

    func sendStreamEnd() {
        // Deepgram streaming protocol: send {"type":"CloseStream"} JSON message to signal
        // end-of-audio. Deepgram will flush any buffered audio, emit a final transcript,
        // then close the WebSocket from its side. The receive loop's .failure case will
        // then fire onDisconnected → deliverTranscript() without waiting for the 4s timeout.
        //
        // NOTE: Do NOT call webSocketTask?.cancel() here — that would abort before Deepgram
        // returns the final transcript. Let Deepgram close the connection gracefully.
        dbg("[Deepgram] sendStreamEnd — sending CloseStream signal")
        let closeMsg = "{\"type\":\"CloseStream\"}"
        webSocketTask?.send(.string(closeMsg)) { error in
            if let error {
                dbg("[Deepgram] sendStreamEnd error: \(error)")
            }
        }
    }

    // MARK: - Activity markers (no-op for Deepgram)

    func sendActivityStart() {}
    func sendActivityBounce() {}

    // MARK: - disconnect

    func disconnect() {
        dbg("[Deepgram] disconnect")
        currentPartialTranscript = ""
        webSocketTask?.cancel(with: .normalClosure, reason: nil)
        webSocketTask = nil
        session?.finishTasksAndInvalidate()
        session = nil
    }
}

// MARK: - URLSessionWebSocketDelegate + URLSessionTaskDelegate

extension DeepgramService: URLSessionWebSocketDelegate, URLSessionTaskDelegate {

    nonisolated func urlSession(
        _ session: URLSession,
        webSocketTask: URLSessionWebSocketTask,
        didOpenWithProtocol protocol: String?
    ) {
        dbg("[Deepgram] WebSocket opened")
        Task { @MainActor [weak self] in
            self?.connectContinuation?.resume()
            self?.connectContinuation = nil
        }
    }

    nonisolated func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didCompleteWithError error: Error?
    ) {
        // Check for 401 Unauthorized
        if let httpResponse = task.response as? HTTPURLResponse,
           httpResponse.statusCode == 401 {
            dbg("[Deepgram] 401 Unauthorized")
            Task { @MainActor [weak self] in
                guard let self else { return }
                // If still connecting, fail the continuation
                if let cont = self.connectContinuation {
                    self.connectContinuation = nil
                    cont.resume(throwing: DeepgramError.unauthorized)
                } else {
                    self.onError?(DeepgramError.unauthorized)
                    self.onDisconnected?()
                }
            }
            return
        }

        if let error {
            dbg("[Deepgram] task completed with error: \(error)")
            Task { @MainActor [weak self] in
                guard let self else { return }
                if let cont = self.connectContinuation {
                    self.connectContinuation = nil
                    cont.resume(throwing: DeepgramError.connectionFailed(error.localizedDescription))
                } else {
                    self.onError?(error)
                    self.onDisconnected?()
                }
            }
        } else if task.response == nil {
            // nil response with no error: treat as connection failure
            dbg("[Deepgram] task completed with nil response — unauthorized or unreachable")
            Task { @MainActor [weak self] in
                guard let self else { return }
                if let cont = self.connectContinuation {
                    self.connectContinuation = nil
                    cont.resume(throwing: DeepgramError.unauthorized)
                } else {
                    self.onError?(DeepgramError.unauthorized)
                    self.onDisconnected?()
                }
            }
        }
    }
}
