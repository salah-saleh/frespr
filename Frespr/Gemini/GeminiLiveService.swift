import Foundation
import Network

enum GeminiLiveError: Error, LocalizedError {
    case missingAPIKey
    case connectionFailed(String)
    case encodingError(Error)
    case decodingError(Error)
    case disconnected

    var errorDescription: String? {
        switch self {
        case .missingAPIKey: return "Gemini API key is not configured. Open Settings to add your key."
        case .connectionFailed(let msg): return "WebSocket connection failed: \(msg)"
        case .encodingError(let e): return "Failed to encode message: \(e.localizedDescription)"
        case .decodingError(let e): return "Failed to decode server message: \(e.localizedDescription)"
        case .disconnected: return "WebSocket disconnected unexpectedly."
        }
    }
}

// MARK: - GeminiLiveService
//
// Uses a raw NWConnection (TLS, no NWProtocolWebSocket) and implements the
// WebSocket HTTP/1.1 upgrade handshake + frame encoding/decoding manually.
//
// Why not NWProtocolWebSocket or URLSessionWebSocketTask?
// - URLSession defaults to HTTP/2 via ALPN; Gemini Live returns 404 on h2.
// - NWProtocolWebSocket sends "GET / HTTP/1.1" for the upgrade, ignoring the
//   URL path, so the API key query string is lost → server rejects.
// - Raw NWConnection lets us send the exact path+query and control ALPN.
//
// ── Issue: transcription lag building up over time ──────────────────────────
//
// SYMPTOM: After 10-20s of recording, the overlay text fell progressively
// further behind what the user was actually saying. Smooth at first, then
// increasingly delayed.
//
// WHY IT HAPPENED (plain): Every 100ms an audio chunk is sent to Gemini. The
// original code fired each send independently without waiting for the previous
// one to finish. Sending data over a network takes a small but non-zero amount
// of time. So sends started piling up: chunk 2 was fired before chunk 1
// finished, then chunk 3, chunk 4... After 20 seconds there were hundreds of
// backed-up chunks waiting to go out. Gemini was transcribing audio from
// 5-10 seconds ago — hence the growing lag.
//
// WHY IT HAPPENED (technical): sendAudioChunk() spawned a new unstructured
// Task per 100ms chunk (10/sec). Each Task called rawSend(), which awaits
// NWConnection.send(.contentProcessed). NWConnection serializes sends
// internally, so all 10 tasks/sec queued behind each other. The queue started
// empty (smooth), but grew by the difference between audio production rate and
// network flush rate — causing a steadily increasing backlog.
//
// FIX: All sends now go through a single serial queue (sendTask drain loop).
// All sendEncodable() calls yield frames to an AsyncStream; one drain task
// processes them one-at-a-time. One chunk goes out, waits for confirmation,
// then the next one goes. The queue stays empty because we never get ahead of
// ourselves. Confirmed via debug log: chunks flow at a steady 10/sec with no
// buildup throughout a full recording session.
//
// REMAINING PERCEIVED DELAY: After this fix, a ~2-3s transcription lag and
// ~4s gaps after each heartbeat bounce are still visible. This is entirely
// Gemini server-side latency — the client is sending audio on time. Nothing
// we can do client-side to reduce this.
//
// ── Issue: words dropped near heartbeat bounces ──────────────────────────────
//
// SYMPTOM: Words spoken around the 8s / 16s / 24s marks occasionally got
// dropped from the transcript.
//
// WHY IT HAPPENED (plain): The heartbeat sends activityEnd then activityStart
// back-to-back (see heartbeat explanation in GeminiSessionCoordinator). Audio
// chunks that were already in-flight when activityEnd was sent could arrive at
// the server AFTER activityStart — the server attributed them to the new
// window instead of the closing one, and those words were lost.
//
// WHY IT HAPPENED (technical): sendActivityBounce() sent activityEnd +
// activityStart with no gap. sendAudioChunk() spawns independent Tasks. Those
// in-flight audio Tasks could reach the server AFTER activityStart, attributing
// audio to the new activity window instead of the closing one.
//
// FIX: 150ms gap between activityEnd and activityStart in sendActivityBounce()
// gives in-flight audio chunks time to drain through the serial queue before
// the new activity window opens.

@MainActor
final class GeminiLiveService: TranscriptionBackend {
    var onTranscriptUpdate: ((String, Bool) -> Void)?
    var onSetupComplete: (() -> Void)?
    var onModelTurnComplete: (() -> Void)?
    var onError: ((Error) -> Void)?
    var onDisconnected: (() -> Void)?

    private var connection: NWConnection?
    private var isConnected = false
    private var receiveTask: Task<Void, Never>?
    private var recvBuffer = Data()
    // Accumulates transcript chunks until turnComplete arrives
    private var transcriptAccumulator = ""

    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    // Serial send queue — all outbound WebSocket frames go through here
    // one at a time. Prevents concurrent rawSend calls from piling up on
    // NWConnection's internal queue, which causes steadily growing lag.
    private var sendQueue: AsyncStream<Data>?
    private var sendQueueContinuation: AsyncStream<Data>.Continuation?
    private var sendTask: Task<Void, Never>?

    // MARK: - Connect

    func connect(apiKey: String) async throws {
        guard !apiKey.isEmpty else { throw GeminiLiveError.missingAPIKey }

        let host = "generativelanguage.googleapis.com"
        let path = "/ws/google.ai.generativelanguage.v1alpha.GenerativeService.BidiGenerateContent"

        dbg("connecting (raw NWConnection + manual WS) to \(host)")

        // Plain TLS — no ALPN restriction needed since we're sending HTTP/1.1
        // manually (no HTTP/2 framing). Server will respond with 101 Upgrade.
        let tlsOpts = NWProtocolTLS.Options()
        let params = NWParameters(tls: tlsOpts)

        let conn = NWConnection(host: NWEndpoint.Host(host), port: 443, using: params)
        connection = conn

        // Wait for TLS to be ready
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            nonisolated(unsafe) var resumed = false
            conn.stateUpdateHandler = { state in
                dbg("NWConnection state: \(state)")
                guard !resumed else { return }
                switch state {
                case .ready:
                    resumed = true; cont.resume()
                case .failed(let e):
                    resumed = true; cont.resume(throwing: GeminiLiveError.connectionFailed("\(e)"))
                case .cancelled:
                    resumed = true; cont.resume(throwing: GeminiLiveError.disconnected)
                default: break
                }
            }
            conn.start(queue: .main)
        }

        dbg("TLS ready — sending WebSocket upgrade")

        // Send HTTP/1.1 WebSocket upgrade request
        let wsKey = Data((0..<16).map { _ in UInt8.random(in: 0...255) }).base64EncodedString()
        let upgradeReq = [
            "GET \(path) HTTP/1.1",
            "Host: \(host)",
            "Upgrade: websocket",
            "Connection: Upgrade",
            "Sec-WebSocket-Key: \(wsKey)",
            "Sec-WebSocket-Version: 13",
            "Origin: https://\(host)",
            "x-goog-api-key: \(apiKey)",
            "", ""
        ].joined(separator: "\r\n")

        try await rawSend(upgradeReq.data(using: .utf8)!)

        // Read HTTP response (until \r\n\r\n)
        let httpResp = try await readUntilHTTPEnd()
        dbg("HTTP upgrade response: \(httpResp.prefix(200))")
        guard httpResp.hasPrefix("HTTP/1.1 101") else {
            throw GeminiLiveError.connectionFailed("Upgrade failed: \(httpResp.prefix(100))")
        }

        isConnected = true
        dbg("WebSocket handshake complete — starting receive + send loops")

        // Start serial send queue drain loop
        let (stream, continuation) = AsyncStream<Data>.makeStream()
        sendQueue = stream
        sendQueueContinuation = continuation
        sendTask = Task { [weak self] in
            guard let self else { return }
            for await frame in stream {
                guard self.isConnected else { break }
                try? await self.rawSend(frame)
            }
            dbg("sendTask drain loop ended")
        }

        receiveTask = Task { [weak self] in await self?.receiveLoop() }

        let setup = GeminiSetupMessage.make()
        try await sendEncodable(setup)
        dbg("setup message sent")
    }

    // MARK: - Raw send

    private func rawSend(_ data: Data) async throws {
        guard let conn = connection else { return }
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            conn.send(content: data, completion: .contentProcessed { err in
                if let err { cont.resume(throwing: GeminiLiveError.connectionFailed("\(err)")) }
                else { cont.resume() }
            })
        }
    }

    // Read from socket until we see \r\n\r\n (end of HTTP headers)
    private func readUntilHTTPEnd() async throws -> String {
        while true {
            if let str = String(data: recvBuffer, encoding: .utf8),
               let range = str.range(of: "\r\n\r\n") {
                let header = String(str[str.startIndex..<range.upperBound])
                let remaining = str[range.upperBound...]
                recvBuffer = remaining.data(using: .utf8) ?? Data()
                return header
            }
            let chunk = try await rawReceive()
            recvBuffer.append(chunk)
        }
    }

    private func rawReceive() async throws -> Data {
        guard let conn = connection else { throw GeminiLiveError.disconnected }
        return try await withCheckedThrowingContinuation { cont in
            conn.receive(minimumIncompleteLength: 1, maximumLength: 65536) { data, _, _, err in
                if let err { cont.resume(throwing: err) }
                else if let data { cont.resume(returning: data) }
                else { cont.resume(returning: Data()) }
            }
        }
    }

    // MARK: - WebSocket Frame Encoding

    // Encode a text frame (opcode 0x1), client-to-server frames must be masked
    private func wsTextFrame(_ text: String) -> Data {
        let payload = text.data(using: .utf8)!
        var frame = Data()

        // FIN + opcode text
        frame.append(0x81)

        // Mask bit set + payload length
        let len = payload.count
        if len < 126 {
            frame.append(UInt8(0x80 | len))
        } else if len < 65536 {
            frame.append(0xFE)
            frame.append(UInt8((len >> 8) & 0xFF))
            frame.append(UInt8(len & 0xFF))
        } else {
            frame.append(0xFF)
            for i in (0..<8).reversed() { frame.append(UInt8((len >> (i*8)) & 0xFF)) }
        }

        // 4-byte masking key
        let mask: [UInt8] = [
            UInt8.random(in: 0...255), UInt8.random(in: 0...255),
            UInt8.random(in: 0...255), UInt8.random(in: 0...255)
        ]
        frame.append(contentsOf: mask)

        // Masked payload
        for (i, byte) in payload.enumerated() {
            frame.append(byte ^ mask[i % 4])
        }
        return frame
    }

    // MARK: - WebSocket Frame Decoding

    // Returns (payload, bytesConsumed) or nil if not enough data yet
    private func parseWSFrame(_ data: Data) -> (Data, Int)? {
        guard data.count >= 2 else { return nil }
        let b0 = data[0], b1 = data[1]
        let opcode = b0 & 0x0F
        let masked = (b1 & 0x80) != 0
        var payloadLen = Int(b1 & 0x7F)
        var offset = 2

        if payloadLen == 126 {
            guard data.count >= 4 else { return nil }
            payloadLen = Int(data[2]) << 8 | Int(data[3])
            offset = 4
        } else if payloadLen == 127 {
            guard data.count >= 10 else { return nil }
            payloadLen = 0
            for i in 0..<8 { payloadLen = payloadLen << 8 | Int(data[2+i]) }
            // RFC 6455 §5.2: MSB must be 0; negative value means high bit set
            guard payloadLen >= 0 else { return nil }
            offset = 10
        }

        let maskLen = masked ? 4 : 0
        guard data.count >= offset + maskLen + payloadLen else { return nil }

        var payload = Data(data[offset + maskLen ..< offset + maskLen + payloadLen])
        if masked {
            let maskBytes = data[offset ..< offset + 4]
            for i in payload.indices { payload[i] ^= maskBytes[maskBytes.startIndex + (i % 4)] }
        }

        // Ignore ping (0x9) and pong (0xA) control frames
        if opcode == 0x9 {
            // Send pong
            let pong = Data([0x8A, 0x00])
            Task { [weak self] in try? await self?.rawSend(pong) }
        }

        return (opcode == 0x8 || opcode == 0x9 || opcode == 0xA) ?
            (Data(), offset + maskLen + payloadLen) :
            (payload, offset + maskLen + payloadLen)
    }

    // MARK: - Send

    /// The partial transcript being accumulated in the current VAD turn.
    /// Exposed so the coordinator can grab it at key-release time.
    var currentTurnTranscript: String { transcriptAccumulator }

    /// TranscriptionBackend conformance — maps to currentTurnTranscript.
    var currentPartialTranscript: String { transcriptAccumulator }

    private var audioChunksSent = 0

    /// TranscriptionBackend conformance — base64-encodes raw PCM then delegates to sendAudioChunk(base64:).
    func sendAudioChunk(data: Data) {
        sendAudioChunkBase64(data.base64EncodedString())
    }

    func sendAudioChunk(base64: String) {
        sendAudioChunkBase64(base64)
    }

    private func sendAudioChunkBase64(_ base64: String) {
        guard isConnected else { return }
        audioChunksSent += 1
        if audioChunksSent == 1 || audioChunksSent % 10 == 0 {
            dbg("sendAudioChunk #\(audioChunksSent) (\(base64.count) chars)")
        }
        let message = GeminiRealtimeInputMessage.audioChunk(base64: base64)
        Task { [weak self] in try? await self?.sendEncodable(message) }
    }

    func sendStreamEnd() {
        guard isConnected else { return }
        dbg("sending activityEnd + audioStreamEnd")
        Task { [weak self] in
            try? await self?.sendEncodable(GeminiActivityMessage.end)
            try? await self?.sendEncodable(GeminiRealtimeInputMessage.streamEnd)
        }
    }

    func sendActivityStart() {
        guard isConnected else { return }
        dbg("sending activityStart")
        Task { [weak self] in try? await self?.sendEncodable(GeminiActivityMessage.start) }
    }

    /// Sends activityEnd immediately followed by activityStart to flush the current
    /// transcription segment and open a new one. Used by the heartbeat timer to work
    /// around the Gemini Live bug where inputAudioTranscription events stop after ~100 chunks.
    func sendActivityBounce() {
        guard isConnected else { return }
        dbg("sending activityEnd + activityStart (bounce)")
        Task { [weak self] in
            try? await self?.sendEncodable(GeminiActivityMessage.end)
            // Small gap lets in-flight audio chunks drain before activityStart so
            // they're attributed to the closing activity rather than the new one.
            try? await Task.sleep(nanoseconds: 150_000_000)  // 150ms
            try? await self?.sendEncodable(GeminiActivityMessage.start)
        }
    }

    private func sendEncodable<T: Encodable>(_ value: T) async throws {
        let data: Data
        do { data = try encoder.encode(value) }
        catch { throw GeminiLiveError.encodingError(error) }
        guard let text = String(data: data, encoding: .utf8) else {
            throw GeminiLiveError.encodingError(GeminiLiveError.disconnected)
        }
        let frame = wsTextFrame(text)
        if let continuation = sendQueueContinuation {
            // Queue is live — enqueue for serial drain (prevents concurrent rawSend buildup)
            continuation.yield(frame)
        } else {
            // Queue not yet started (HTTP upgrade phase) — send directly
            try await rawSend(frame)
        }
    }

    // MARK: - Receive Loop

    private func receiveLoop() async {
        dbg("receiveLoop started")
        while !Task.isCancelled && isConnected {
            do {
                // Read more data into buffer
                let chunk = try await rawReceive()
                recvBuffer.append(chunk)

                // Parse all complete frames from buffer
                while let (payload, consumed) = parseWSFrame(recvBuffer) {
                    recvBuffer = recvBuffer.dropFirst(consumed).asData()
                    if !payload.isEmpty {
                        await handleData(payload)
                    }
                }
            } catch {
                dbg("receiveLoop error: \(error)")
                if isConnected {
                    isConnected = false
                    await MainActor.run { [weak self] in self?.onDisconnected?() }
                }
                break
            }
        }
        dbg("receiveLoop ended")
    }

    private func handleData(_ data: Data) async {
        let raw = String(data: data, encoding: .utf8) ?? "<binary \(data.count) bytes>"
        dbg("received: \(raw.prefix(200))")
        do {
            let serverMsg = try decoder.decode(GeminiServerMessage.self, from: data)
            await MainActor.run { [weak self] in self?.process(serverMsg) }
        } catch {
            dbg("decode error: \(error) raw: \(raw.prefix(500))")
        }
    }

    @MainActor
    private func process(_ msg: GeminiServerMessage) {
        if msg.setupComplete != nil {
            dbg("setupComplete received")
            onSetupComplete?()
            return
        }
        if msg.goAway != nil {
            dbg("goAway received — server will disconnect soon")
            return
        }
        if let content = msg.serverContent {
            // Ignore model audio/text responses (modelTurn) — we only care about inputTranscription.
            // The native audio model may generate responses despite system instructions;
            // processing them would block transcription updates.
            if content.modelTurn != nil {
                dbg("ignoring modelTurn content")
                // Still check for turnComplete/generationComplete on this message
            }

            // Accumulate transcript chunks as they arrive (interim updates)
            if let transcription = content.inputTranscription, let text = transcription.text, !text.isEmpty {
                transcriptAccumulator += text
                dbg("transcript chunk: '\(text)' accumulated: '\(transcriptAccumulator)'")
                onTranscriptUpdate?(transcriptAccumulator, false)
            }
            // generationComplete means the model finished its audio response.
            // Notify coordinator so it can re-send activityStart and resume transcription.
            if content.generationComplete == true {
                dbg("generationComplete — model response done, notifying coordinator to resume")
                onModelTurnComplete?()
            }

            // Fire final transcript on turnComplete only (not generationComplete —
            // that's the model's own response finishing, not the user's speech turn).
            if content.turnComplete == true && !transcriptAccumulator.isEmpty {
                let final = transcriptAccumulator.trimmingCharacters(in: .whitespaces)
                dbg("turnComplete — final: '\(final)'")
                transcriptAccumulator = ""
                if !final.isEmpty {
                    onTranscriptUpdate?(final, true)
                }
            }
        }
    }

    // MARK: - Disconnect

    func disconnect() {
        dbg("disconnect called, total audio chunks sent: \(audioChunksSent)")
        audioChunksSent = 0
        transcriptAccumulator = ""
        isConnected = false
        receiveTask?.cancel()
        receiveTask = nil
        sendQueueContinuation?.finish()
        sendQueueContinuation = nil
        sendQueue = nil
        sendTask?.cancel()
        sendTask = nil
        connection?.cancel()
        connection = nil
        recvBuffer = Data()
    }
}

// MARK: - Helpers
private extension DataProtocol {
    func asData() -> Data { Data(self) }
}
