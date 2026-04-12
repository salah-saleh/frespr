import Foundation
import AppKit

@MainActor
final class TranscriptionCoordinator {
    // Callbacks for UI updates
    var onStateChange: ((SessionState) -> Void)?
    var onTranscriptUpdate: ((String, Bool) -> Void)?  // (text, isFinal)
    var onError: ((String) -> Void)?

    private let audioEngine = AudioCaptureEngine()
    private var backend: (any TranscriptionBackend)?
    private let settings = AppSettings.shared

    private(set) var state: SessionState = .idle {
        didSet { onStateChange?(state) }
    }

    private var isToggled = false
    private var isDelivering = false  // guards against double-delivery
    // Set when key-up fires while still .connecting (connection not yet complete).
    // setupComplete checks this and stops immediately instead of starting to record.
    private var pendingStop = false
    private var silenceChunkCount = 0
    private var transcriptHeartbeatTimer: Timer?
    private var heartbeatBounceInFlight = false  // suppresses redundant activityStart after bounce

    // Auto-calibrated silence threshold.
    // Computed at session start by sampling the first N ambient chunks, then set to
    // baseline * 2.5. Falls back to 0.006 if calibration produces an unreasonably
    // low value (dead-silent room or bad mic). Never goes below the floor.
    private var silenceLevelThreshold: Float = 0.006
    private let silenceThresholdFloor: Float = 0.003
    private let silenceCalibrationChunks = 5  // ~500ms at 10 chunks/sec
    private var calibrationSamples: [Float] = []
    private var isCalibrated = false

    private var silenceDbgLogged = false  // throttle: log state/setting guard failure only once per recording

    // Accumulates all final transcript segments delivered by the server's VAD
    // while the user is still recording. Only injected when the user ends the session.
    private var accumulatedTranscript = ""

    // Audio chunks captured while still connecting (before setupComplete).
    // Flushed to the backend once the session is ready.
    private var connectBuffer: [Data] = []

    // MARK: - Internal Test Hooks

    /// Exposes connectBuffer for regression testing only.
    var testConnectBuffer: [Data] { connectBuffer }

    /// Simulates an audio chunk arriving while in .connecting state (for regression testing).
    func testInjectAudioChunk(_ data: Data) {
        if state == .connecting {
            connectBuffer.append(data)
        }
    }

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
        // Backend is created lazily in startRecording() based on which API keys are set.
    }

    // MARK: - Setup

    private func setupBackendCallbacks() {
        backend?.onSetupComplete = { [weak self] in
            Task { @MainActor [weak self] in
                guard let self = self, self.state == .connecting else { return }

                // Key was released before connection completed — stop now instead of recording.
                if self.pendingStop {
                    dbg("setupComplete: pendingStop set — stopping immediately (key released during connect)")
                    self.pendingStop = false
                    self.cleanup()
                    return
                }

                self.state = .recording
                // Tell the backend we're starting a speech activity.
                // Deepgram ignores this (no-op); kept for protocol conformance.
                self.backend?.sendActivityStart()

                // Flush any audio buffered during the connection handshake.
                if !self.connectBuffer.isEmpty {
                    dbg("flushing \(self.connectBuffer.count) pre-connect audio chunks")
                    for chunk in self.connectBuffer {
                        self.backend?.sendAudioChunk(data: chunk)
                    }
                    self.connectBuffer.removeAll()
                }
            }
        }

        // NOTE: process() in GeminiLiveService is @MainActor and calls this
        // callback synchronously, so we must NOT wrap in Task { @MainActor }
        // — that would re-queue and cause a race where stopRecording() runs
        // before accumulatedTranscript is updated.
        backend?.onTranscriptUpdate = { [weak self] text, isFinal in
            guard let self else { return }
            if isFinal {
                // Normalize each segment individually before appending so that
                // ALL-CAPS turns get fixed without affecting already-correct turns.
                let normalized = self.normalizeTranscription(text)
                // Skip noise-only segments that normalize to empty string.
                guard !normalized.isEmpty else { return }
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
                let filtered = self.normalizeTranscription(text)
                let display = self.accumulatedTranscript.isEmpty
                    ? filtered
                    : self.accumulatedTranscript + " " + filtered
                self.onTranscriptUpdate?(display, false)
            }
        }

        backend?.onError = { [weak self] error in
            Task { @MainActor [weak self] in
                dbg("backend.onError: \(error.localizedDescription)")
                AudioFeedback.shared.playError()
                self?.state = .error(error.localizedDescription)
                self?.onError?(error.localizedDescription)
                self?.cleanup()
            }
        }

        backend?.onDisconnected = { [weak self] in
            Task { @MainActor [weak self] in
                guard let self = self else { return }
                dbg("backend.onDisconnected state=\(self.state)")
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

        let deepgramKey = settings.deepgramAPIKey

        // v2.0: Deepgram is the sole transcription backend. Gemini Live is no longer
        // used for transcription — Gemini is optional for post-processing/translation only.
        // Reset to .idle after showing the error so the next hotkey press re-triggers
        // the warning rather than getting stuck in .error state permanently.
        guard !deepgramKey.isEmpty else {
            let msg = "Add a Deepgram API key in Settings to start transcribing."
            onError?(msg)
            // Stay .idle so handleHotkeyPress can retry on the next press
            return
        }
        backend = DeepgramService()

        setupBackendCallbacks()

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

            // Abort if state changed OR user double-tapped (isToggled cleared by handleHotkeyPress)
            guard self.state == .idle, self.isToggled else { return }

            self.accumulatedTranscript = ""
            self.connectBuffer.removeAll()
            dbg("startRecording — starting audio capture immediately, then connecting")
            AudioFeedback.shared.playStart()
            self.state = .connecting
            self.startAudioCapture()

            let apiKey = deepgramKey  // always Deepgram in v2.0
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
        // If still connecting, defer the stop until setupComplete fires.
        // This handles the case where the user releases the key before the
        // WebSocket handshake completes (e.g. quick tap ~150-300ms).
        if state == .connecting {
            dbg("stopRecording: still connecting — deferring stop via pendingStop")
            pendingStop = true
            return
        }
        AudioFeedback.shared.playStop()
        state = .processing
        audioEngine.stop()

        // Grab whatever partial transcript the current VAD turn has accumulated
        // in the service layer — this is the text from the final in-flight segment
        // that may never get a turnComplete (server can take seconds to respond).
        backend?.sendStreamEnd()

        // Wait for the server to return turnComplete for the final segment.
        //
        // History of this timeout:
        //   5000ms → 700ms → 1200ms → 600ms → 1500ms → poll-up-to-4000ms (current)
        //
        // Why it kept breaking:
        //   A fixed sleep races against variable server latency. Gemini needs
        //   2-4s to return turnComplete after activityEnd, especially when a
        //   heartbeat bounce fired recently (bounce at t=0, key release at t=3
        //   means activityEnd was just sent ~3s into a fresh turn — server may
        //   not have accumulated enough audio to close the turn quickly).
        //   Any fixed value either felt slow (5s) or dropped final words (600ms).
        //
        // Current approach: poll state every 100ms for up to 4s.
        //   - turnComplete fires → deliverTranscript() → state becomes .idle.
        //   - The poll detects state != .processing and exits immediately.
        //   - No wasted wait time when the server is fast (common case: ~1-2s).
        //   - 4s hard cap catches the rare case where turnComplete never arrives
        //     (connection drop, server bug) — snap currentTurnTranscript partial.
        // BUG FIX: was plain Task {} (background thread) — calling @MainActor methods
        // (deliverTranscript, cleanup) from a non-isolated context is undefined in Swift 6.
        Task { @MainActor in
            for _ in 0..<40 {
                try? await Task.sleep(nanoseconds: 100_000_000)  // 100ms
                guard self.state == .processing else { return }  // turnComplete already delivered
            }
            // 4s elapsed and no turnComplete — snap whatever partial we have
            let partial = self.normalizeTranscription(self.backend?.currentPartialTranscript ?? "")
            if !partial.isEmpty {
                dbg("stopRecording: snapping partial turn after 4s: '\(partial.prefix(80))'")
                if !self.accumulatedTranscript.isEmpty { self.accumulatedTranscript += " " }
                self.accumulatedTranscript += partial
            }
            dbg("stopRecording: delivering after 4s timeout, total len=\(self.accumulatedTranscript.count)")
            self.deliverTranscript()
        }
    }

    // MARK: - Private

    /// Connects to the backend with up to 3 attempts and exponential backoff.
    /// Does not retry on DeepgramError.unauthorized (invalid key — retrying won't help).
    private func connectWithRetry(apiKey: String, maxAttempts: Int = 3) async throws {
        var lastError: Error?
        for attempt in 1...maxAttempts {
            do {
                try await backend!.connect(apiKey: apiKey)
                return
            } catch DeepgramError.unauthorized {
                // Invalid key — no point retrying
                throw DeepgramError.unauthorized
            } catch {
                lastError = error
                guard attempt < maxAttempts, state == .connecting else { break }
                let backoffMs = Int(pow(2.0, Double(attempt - 1))) * 150
                dbg("connection attempt \(attempt) failed, retrying in \(backoffMs)ms")
                try? await Task.sleep(nanoseconds: UInt64(backoffMs) * 1_000_000)
            }
        }
        throw lastError ?? TranscriptionError.connectionFailed("Max retries exceeded")
    }

    private func startAudioCapture() {
        silenceChunkCount = 0
        silenceDbgLogged = false  // reset one-shot diagnostic flag each recording
        calibrationSamples = []
        isCalibrated = false

        audioEngine.onAudioChunk = { [weak self] data in
            Task { @MainActor [weak self] in
                guard let self else { return }
                if self.state == .connecting {
                    // Not yet connected — buffer for later flush.
                    self.connectBuffer.append(data)
                } else {
                    self.backend?.sendAudioChunk(data: data)
                }
            }
        }

        audioEngine.onAudioLevel = { [weak self] rms in
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }

                // --- Ambient calibration phase (runs during .connecting) ---
                // We sample ambient noise while the WebSocket handshake is in progress
                // (before the user is expected to speak). This gives a clean baseline
                // uncontaminated by speech. By the time state → .recording the threshold
                // is already set and we go straight into active detection.
                if self.state == .connecting && !self.isCalibrated {
                    self.calibrationSamples.append(rms)
                    if self.calibrationSamples.count >= self.silenceCalibrationChunks {
                        let baseline = self.calibrationSamples.reduce(0, +) / Float(self.calibrationSamples.count)
                        let calibrated = max(baseline * 2.5, self.silenceThresholdFloor)
                        self.silenceLevelThreshold = calibrated
                        self.isCalibrated = true
                        dbg("[silence-calibrate] baseline=\(String(format: "%.4f", baseline)) threshold=\(String(format: "%.4f", calibrated))")
                    }
                    return
                }

                guard self.state == .recording else { return }
                guard AppSettings.shared.silenceDetectionEnabled else { return }

                // If connection was so fast that calibration didn't finish, fall back
                // to the hardcoded floor so we don't fire on every chunk.
                if !self.isCalibrated {
                    self.silenceLevelThreshold = self.silenceThresholdFloor
                    self.isCalibrated = true
                    dbg("[silence-calibrate] fast-connect fallback threshold=\(String(format: "%.4f", self.silenceThresholdFloor))")
                }

                // --- Active silence detection ---
                let timeoutSecs = AppSettings.shared.silenceTimeoutSeconds > 0
                    ? AppSettings.shared.silenceTimeoutSeconds : 5
                let timeoutChunks = timeoutSecs * 10
                if rms < self.silenceLevelThreshold {
                    self.silenceChunkCount += 1
                    dbg("[silence] chunk \(self.silenceChunkCount)/\(timeoutChunks) rms=\(String(format: "%.4f", rms)) threshold=\(String(format: "%.4f", self.silenceLevelThreshold))")
                    if self.silenceChunkCount >= timeoutChunks {
                        dbg("[silence] timeout reached — auto-stopping")
                        self.stopRecording()
                    }
                } else {
                    if self.silenceChunkCount > 0 {
                        dbg("[silence] reset (was \(self.silenceChunkCount)) rms=\(String(format: "%.4f", rms))")
                    }
                    self.silenceChunkCount = 0
                }
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

        // T039: if post-processing is requested but no Gemini key is set, warn and inject raw.
        let postMode = settings.postProcessingMode
        if postMode != .none && settings.geminiAPIKey.isEmpty {
            dbg("deliverTranscript: post-processing requires Gemini key — injecting raw")
            onTranscriptUpdate?("Post-processing requires a Gemini API key.", false)
            Task { @MainActor in
                TranscriptionLog.shared.add(text: rawText)
                self.onTranscriptUpdate?(rawText, true)
                if self.settings.copyToClipboard {
                    let pb = NSPasteboard.general
                    pb.clearContents()
                    pb.setString(rawText, forType: .string)
                }
                AudioFeedback.shared.playSuccess()
                self.cleanup()
                try? await Task.sleep(nanoseconds: 200_000_000)
                dbg("injecting (no postprocess key): '\(rawText.prefix(80))'")
                TextInjector.shared.inject(text: rawText)
            }
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
        // Strip bracketed noise/sound annotations Gemini emits (e.g. [noise], [music], [laughter]).
        var result = text.replacingOccurrences(of: "\\[[^\\]]*\\]", with: "", options: .regularExpression)
        // Collapse any double-spaces left behind after stripping annotations.
        result = result.replacingOccurrences(of: "  +", with: " ", options: .regularExpression)
        result = result.trimmingCharacters(in: .whitespaces)

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
        dbg("cleanup: state was \(state) — resetting to idle")
        transcriptHeartbeatTimer?.invalidate()
        transcriptHeartbeatTimer = nil
        heartbeatBounceInFlight = false
        audioEngine.stop()
        backend?.disconnect()
        backend = nil
        state = .idle
        isToggled = false
        isDelivering = false
        pendingStop = false
        silenceChunkCount = 0
        silenceDbgLogged = false
        calibrationSamples = []
        isCalibrated = false
        connectBuffer.removeAll()
    }

    // MARK: - Hotkey

    func handleHotkeyPress() {
        dbg("handleHotkeyPress state=\(state) isToggled=\(isToggled)")
        switch state {
        case .idle:
            if isToggled {
                // Second tap arrived while still in async startup (state hasn't moved
                // to .connecting yet) — cancel the in-flight start.
                dbg("handleHotkeyPress: double-tap during async startup — cancelling")
                isToggled = false
                // startRecording() guards on state == .idle so it will abort itself.
                // Nothing else to do here.
            } else {
                isToggled = true
                startRecording()
            }
        case .recording, .connecting:
            isToggled = false
            stopRecording()
        case .processing:
            // Cancel the in-flight processing so the user can start fresh.
            cancelRecording()
        case .error:
            // Reset to idle and retry — allows re-showing the warning on every press.
            state = .idle
            isToggled = true
            startRecording()
        }
    }
}
