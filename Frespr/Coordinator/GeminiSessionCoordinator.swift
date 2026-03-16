import Foundation
import AppKit

@MainActor
final class GeminiSessionCoordinator {
    // Callbacks for UI updates
    var onStateChange: ((SessionState) -> Void)?
    var onTranscriptUpdate: ((String, Bool) -> Void)?  // (text, isFinal)
    var onError: ((String) -> Void)?

    private let audioEngine = AudioCaptureEngine()
    private let geminiService = GeminiLiveService()
    private let settings = AppSettings.shared

    private(set) var state: SessionState = .idle {
        didSet { onStateChange?(state) }
    }

    private var isToggled = false
    private var isDelivering = false  // guards against double-delivery
    private var silenceChunkCount = 0
    private var transcriptHeartbeatTimer: Timer?
    private var heartbeatBounceInFlight = false  // suppresses redundant activityStart after bounce
    private let silenceLevelThreshold: Float = 0.01

    // Accumulates all final transcript segments delivered by the server's VAD
    // while the user is still recording. Only injected when the user ends the session.
    private var accumulatedTranscript = ""

    // Audio chunks captured while still connecting (before setupComplete).
    // Flushed to Gemini once the session is ready.
    private var connectBuffer: [String] = []

    enum SessionState: Equatable {
        case idle
        case connecting
        case recording
        case processing
        case error(String)

        static func == (lhs: SessionState, rhs: SessionState) -> Bool {
            switch (lhs, rhs) {
            case (.idle, .idle), (.connecting, .connecting), (.recording, .recording), (.processing, .processing):
                return true
            case (.error(let a), .error(let b)):
                return a == b
            default:
                return false
            }
        }
    }

    init() {
        setupGeminiCallbacks()
    }

    // MARK: - Setup

    private func setupGeminiCallbacks() {
        geminiService.onModelTurnComplete = { [weak self] in
            guard let self, self.state == .recording else { return }
            // If a heartbeat bounce just sent activityEnd+activityStart, skip the
            // redundant activityStart here — the bounce already reopened the activity.
            if self.heartbeatBounceInFlight {
                dbg("onModelTurnComplete: skipping activityStart (heartbeat bounce in flight)")
                self.heartbeatBounceInFlight = false
                return
            }
            // Model finished its audio response — re-send activityStart so the server
            // resumes transcribing the ongoing audio stream.
            dbg("onModelTurnComplete: re-sending activityStart to resume transcription")
            self.geminiService.sendActivityStart()
        }

        geminiService.onSetupComplete = { [weak self] in
            Task { @MainActor [weak self] in
                guard let self = self, self.state == .connecting else { return }
                self.state = .recording
                // Tell the server we're starting a speech activity (VAD is disabled,
                // so without this the server won't know we're speaking).
                self.geminiService.sendActivityStart()
                // Start heartbeat to keep transcription events flowing (Gemini Live bug workaround)
                self.transcriptHeartbeatTimer = Timer.scheduledTimer(withTimeInterval: 8.0, repeats: true) { [weak self] _ in
                    Task { @MainActor [weak self] in
                        guard let self, self.state == .recording else { return }
                        dbg("heartbeat: sending activityEnd+activityStart to flush transcription segment")
                        self.heartbeatBounceInFlight = true
                        self.geminiService.sendActivityBounce()
                    }
                }
                // Flush any audio buffered during the connection handshake.
                if !self.connectBuffer.isEmpty {
                    dbg("flushing \(self.connectBuffer.count) pre-connect audio chunks")
                    for base64 in self.connectBuffer {
                        self.geminiService.sendAudioChunk(base64: base64)
                    }
                    self.connectBuffer.removeAll()
                }
            }
        }

        // NOTE: process() in GeminiLiveService is @MainActor and calls this
        // callback synchronously, so we must NOT wrap in Task { @MainActor }
        // — that would re-queue and cause a race where stopRecording() runs
        // before accumulatedTranscript is updated.
        geminiService.onTranscriptUpdate = { [weak self] text, isFinal in
            guard let self else { return }
            if isFinal {
                // Normalize each segment individually before appending so that
                // ALL-CAPS turns get fixed without affecting already-correct turns.
                let normalized = self.normalizeTranscription(text)
                if !self.accumulatedTranscript.isEmpty {
                    self.accumulatedTranscript += " "
                }
                self.accumulatedTranscript += normalized
                dbg("segment final (normalized): '\(normalized.prefix(80))' total len=\(self.accumulatedTranscript.count) state=\(self.state)")

                if self.state == .processing {
                    // User already released the key — deliver now.
                    self.deliverTranscript()
                } else {
                    // Still recording — show full accumulated text as interim.
                    self.onTranscriptUpdate?(self.accumulatedTranscript, false)
                }
            } else {
                // Interim update — show prior segments + current partial.
                let display = self.accumulatedTranscript.isEmpty
                    ? text
                    : self.accumulatedTranscript + " " + text
                self.onTranscriptUpdate?(display, false)
            }
        }

        geminiService.onError = { [weak self] error in
            Task { @MainActor [weak self] in
                dbg("geminiService.onError: \(error.localizedDescription)")
                AudioFeedback.shared.playError()
                self?.state = .error(error.localizedDescription)
                self?.onError?(error.localizedDescription)
                self?.cleanup()
            }
        }

        geminiService.onDisconnected = { [weak self] in
            Task { @MainActor [weak self] in
                guard let self = self else { return }
                dbg("geminiService.onDisconnected state=\(self.state)")
                if self.state != .idle {
                    // If we have accumulated text, deliver it before cleaning up.
                    if self.state == .processing && !self.accumulatedTranscript.isEmpty {
                        self.deliverTranscript()
                    } else {
                        self.cleanup()
                    }
                }
            }
        }
    }

    // MARK: - Public Interface

    /// Cancels any in-progress recording (e.g. Escape pressed).
    func cancelRecording() {
        guard state == .recording || state == .connecting || state == .processing else { return }
        dbg("cancelRecording")
        accumulatedTranscript = ""
        cleanup()
    }

    /// Called when hotkey is pressed (in hold mode) or first press (in toggle mode)
    func startRecording() {
        guard state == .idle else { return }

        let apiKey = settings.geminiAPIKey
        guard !apiKey.isEmpty else {
            let msg = "Gemini API key not configured. Open Settings (⌘,) to add your key."
            state = .error(msg)
            onError?(msg)
            return
        }

        Task { @MainActor in
            // If mic permission hasn't been granted yet, request it now and wait.
            if !PermissionManager.shared.microphoneAuthorized {
                let granted = await PermissionManager.shared.requestMicrophoneAccess()
                guard granted else {
                    let msg = "Microphone access is required. Grant it in System Settings → Privacy → Microphone."
                    self.state = .error(msg)
                    self.onError?(msg)
                    return
                }
                // Small delay so AVAudioEngine's inputNode re-initialises with the real format.
                try? await Task.sleep(nanoseconds: 300_000_000)
            }

            guard self.state == .idle else { return }  // user may have pressed again

            self.accumulatedTranscript = ""
            self.connectBuffer.removeAll()
            dbg("startRecording — starting audio capture immediately, then connecting")
            AudioFeedback.shared.playStart()
            self.state = .connecting
            self.startAudioCapture()

            do {
                try await self.connectWithRetry(apiKey: apiKey)
            } catch {
                self.state = .error(error.localizedDescription)
                self.onError?(error.localizedDescription)
                self.cleanup()
            }
        }
    }

    /// Called when hotkey is released (hold mode) or second press (toggle mode)
    func stopRecording() {
        guard state == .recording || state == .connecting else { return }
        AudioFeedback.shared.playStop()
        state = .processing
        audioEngine.stop()

        // Grab whatever partial transcript the current VAD turn has accumulated
        // in the service layer — this is the text from the final in-flight segment
        // that may never get a turnComplete (server can take seconds to respond).
        geminiService.sendStreamEnd()

        // Wait for the last in-flight audio chunks to arrive and be
        // transcribed. Most transcripts arrive via turnComplete (which
        // triggers immediate delivery at line 89-91). This fallback timer
        // catches the rare case where turnComplete hasn't fired yet.
        Task {
            try? await Task.sleep(nanoseconds: 600_000_000)  // 600ms collection window
            guard self.state == .processing else { return }  // already delivered via turnComplete

            let partial = self.normalizeTranscription(self.geminiService.currentTurnTranscript)
            if !partial.isEmpty {
                dbg("stopRecording: snapping partial turn: '\(partial.prefix(80))'")
                if !self.accumulatedTranscript.isEmpty { self.accumulatedTranscript += " " }
                self.accumulatedTranscript += partial
            }
            dbg("stopRecording: delivering after 600ms, total len=\(self.accumulatedTranscript.count)")
            self.deliverTranscript()
        }
    }

    // MARK: - Private

    /// Connects to Gemini with up to 3 attempts and exponential backoff.
    private func connectWithRetry(apiKey: String, maxAttempts: Int = 3) async throws {
        var lastError: Error?
        for attempt in 1...maxAttempts {
            do {
                try await geminiService.connect(apiKey: apiKey)
                return
            } catch {
                lastError = error
                guard attempt < maxAttempts, state == .connecting else { break }
                let backoffMs = Int(pow(2.0, Double(attempt - 1))) * 150
                dbg("connection attempt \(attempt) failed, retrying in \(backoffMs)ms")
                try? await Task.sleep(nanoseconds: UInt64(backoffMs) * 1_000_000)
            }
        }
        throw lastError ?? GeminiLiveError.connectionFailed("Max retries exceeded")
    }

    private func startAudioCapture() {
        silenceChunkCount = 0

        audioEngine.onAudioChunk = { [weak self] data in
            let base64 = data.base64EncodedString()
            Task { @MainActor [weak self] in
                guard let self else { return }
                if self.state == .connecting {
                    // Not yet connected — buffer for later flush.
                    self.connectBuffer.append(base64)
                } else {
                    self.geminiService.sendAudioChunk(base64: base64)
                }
            }
        }

        audioEngine.onAudioLevel = { [weak self] rms in
            guard let self, self.state == .recording else { return }
            guard AppSettings.shared.silenceDetectionEnabled else { return }
            if rms < self.silenceLevelThreshold {
                self.silenceChunkCount += 1
                let timeoutChunks = AppSettings.shared.silenceTimeoutSeconds * 10
                if self.silenceChunkCount >= timeoutChunks {
                    Task { @MainActor [weak self] in
                        self?.stopRecording()
                    }
                }
            } else {
                self.silenceChunkCount = 0
            }
        }

        do {
            try audioEngine.start()
            // State stays .connecting until setupComplete is received.
        } catch {
            state = .error(error.localizedDescription)
            onError?(error.localizedDescription)
            cleanup()
        }
    }

    /// Injects the accumulated transcript, optionally post-processing it first.
    private func deliverTranscript() {
        guard !isDelivering else { return }
        isDelivering = true

        let rawText = accumulatedTranscript.trimmingCharacters(in: .whitespaces)
        accumulatedTranscript = ""

        guard !rawText.isEmpty else {
            cleanup()
            return
        }

        Task { @MainActor in
            // Translate first (if enabled), then post-process
            let translatedText = await self.translate(rawText)
            let finalText = await self.postProcess(translatedText)

            // Save to history log
            TranscriptionLog.shared.add(text: finalText)

            // Show final text in overlay
            self.onTranscriptUpdate?(finalText, true)

            // Copy to clipboard if enabled
            if self.settings.copyToClipboard {
                let pb = NSPasteboard.general
                pb.clearContents()
                pb.setString(finalText, forType: .string)
            }

            // Cleanup (hides overlay, restores focus to target app), then inject
            AudioFeedback.shared.playSuccess()
            self.cleanup()
            try? await Task.sleep(nanoseconds: 200_000_000)  // 200ms for OS focus restore
            dbg("injecting: '\(finalText.prefix(80))'")
            TextInjector.shared.inject(text: finalText)
        }
    }

    /// Applies the configured post-processing mode. Always returns a string —
    /// falls back to rawText on any error or if mode is .none.
    private func postProcess(_ rawText: String) async -> String {
        let mode = settings.postProcessingMode
        guard mode != .none else { return rawText }

        let systemPrompt: String
        switch mode {
        case .none:
            return rawText
        case .cleanup, .summarize:
            guard let prompt = mode.systemPrompt else { return rawText }
            systemPrompt = prompt
        case .custom:
            let custom = settings.customPostProcessingPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !custom.isEmpty else { return rawText }
            systemPrompt = custom
        }

        let apiKey = settings.geminiAPIKey
        guard !apiKey.isEmpty else { return rawText }

        do {
            dbg("postProcess mode=\(mode.rawValue)")
            let result = try await GeminiPostProcessor.process(
                rawText: rawText,
                systemPrompt: systemPrompt,
                apiKey: apiKey
            )
            dbg("postProcess done: '\(result.prefix(80))'")
            return result
        } catch {
            dbg("postProcess error (using raw): \(error.localizedDescription)")
            return rawText
        }
    }

    /// Translates rawText to the configured target language. Returns rawText unchanged
    /// if translation is disabled, target == source, or an error occurs.
    private func translate(_ rawText: String) async -> String {
        guard settings.translationEnabled else { return rawText }

        let source = settings.translationSourceLanguage
        let target = settings.translationTargetLanguage
        let apiKey = settings.geminiAPIKey
        guard !apiKey.isEmpty else { return rawText }

        let sourceHint = source == "Auto-detect" ? "" : " from \(source)"
        let systemPrompt = "You are a professional translator. Translate the following text\(sourceHint) into \(target). Output only the translated text and nothing else. Do not add explanations, comments, or quotation marks."

        do {
            dbg("translate → \(target)")
            let result = try await GeminiPostProcessor.process(
                rawText: rawText,
                systemPrompt: systemPrompt,
                apiKey: apiKey
            )
            dbg("translate done: '\(result.prefix(80))'")
            return result
        } catch {
            dbg("translate error (using raw): \(error.localizedDescription)")
            return rawText
        }
    }

    /// Fixes ALL-CAPS and other formatting artifacts from the native audio model.
    private func normalizeTranscription(_ text: String) -> String {
        var result = text.trimmingCharacters(in: .whitespaces)

        // If the entire text (ignoring punctuation) is uppercase, convert to
        // sentence case. The native audio model in AUDIO mode often returns
        // ALL CAPS transcriptions.
        let letters = result.unicodeScalars.filter { CharacterSet.letters.contains($0) }
        let uppercaseLetters = letters.filter { CharacterSet.uppercaseLetters.contains($0) }
        if letters.count > 1 && uppercaseLetters.count == letters.count {
            result = toSentenceCase(result)
        }

        return result
    }

    /// Converts "HELLO WORLD. HOW ARE YOU" → "Hello world. How are you"
    private func toSentenceCase(_ text: String) -> String {
        let lower = text.lowercased()
        var chars = Array(lower)
        var capitalizeNext = true
        for i in chars.indices {
            if capitalizeNext && chars[i].isLetter {
                chars[i] = Character(chars[i].uppercased())
                capitalizeNext = false
            }
            if chars[i] == "." || chars[i] == "!" || chars[i] == "?" {
                capitalizeNext = true
            }
        }
        return String(chars)
    }

    private func cleanup() {
        transcriptHeartbeatTimer?.invalidate()
        transcriptHeartbeatTimer = nil
        heartbeatBounceInFlight = false
        audioEngine.stop()
        geminiService.disconnect()
        state = .idle
        isToggled = false
        isDelivering = false
        silenceChunkCount = 0
        connectBuffer.removeAll()
    }

    // MARK: - Hotkey

    func handleHotkeyPress() {
        dbg("handleHotkeyPress state=\(state)")
        switch state {
        case .idle:
            isToggled = true
            startRecording()
        case .recording, .connecting:
            isToggled = false
            stopRecording()
        case .processing:
            // Cancel the in-flight processing so the user can start fresh.
            cancelRecording()
        case .error:
            break
        }
    }
}
