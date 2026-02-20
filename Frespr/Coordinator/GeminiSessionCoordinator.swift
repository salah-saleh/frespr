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

    private var isToggled = false  // For toggle mode

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
        geminiService.onSetupComplete = { [weak self] in
            Task { @MainActor [weak self] in
                guard let self = self, self.state == .connecting else { return }
                self.startAudioCapture()
            }
        }

        geminiService.onTranscriptUpdate = { [weak self] text, isFinal in
            Task { @MainActor [weak self] in
                self?.onTranscriptUpdate?(text, isFinal)
                if isFinal {
                    self?.handleFinalTranscript(text)
                }
            }
        }

        geminiService.onError = { [weak self] error in
            Task { @MainActor [weak self] in
                dbg("geminiService.onError: \(error.localizedDescription)")
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
                    self.cleanup()
                }
            }
        }
    }

    // MARK: - Public Interface

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

        dbg("startRecording — connecting")
        state = .connecting

        Task {
            do {
                try await geminiService.connect(apiKey: apiKey)
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
        state = .processing
        audioEngine.stop()
        geminiService.sendStreamEnd()
        // Final transcript will arrive via onTranscriptUpdate(isFinal: true)
        // Set a timeout in case nothing comes back
        Task {
            try? await Task.sleep(nanoseconds: 5_000_000_000)  // 5 second timeout
            if self.state == .processing {
                self.cleanup()
            }
        }
    }

    // MARK: - Private

    private func startAudioCapture() {
        audioEngine.onAudioChunk = { [weak self] data in
            let base64 = data.base64EncodedString()
            Task { @MainActor [weak self] in
                self?.geminiService.sendAudioChunk(base64: base64)
            }
        }

        do {
            try audioEngine.start()
            state = .recording
        } catch {
            state = .error(error.localizedDescription)
            onError?(error.localizedDescription)
            cleanup()
        }
    }

    private func handleFinalTranscript(_ text: String) {
        guard !text.isEmpty else {
            cleanup()
            return
        }
        // Cleanup first (hides overlay, sets state=idle) so the target app
        // gets focus back, then inject after a brief delay for the OS to
        // restore focus to the previously active text field.
        cleanup()
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 150_000_000)  // 150ms
            dbg("injecting: '\(text.prefix(80))'")
            TextInjector.shared.inject(text: text)
        }
    }

    private func cleanup() {
        audioEngine.stop()
        geminiService.disconnect()
        state = .idle
        isToggled = false
    }

    // MARK: - Toggle Mode Support

    func handleHotkeyPress() {
        dbg("handleHotkeyPress state=\(state) mode=\(settings.hotkeyMode)")
        switch settings.hotkeyMode {
        case .hold:
            startRecording()
        case .toggle:
            if state == .idle {
                isToggled = true
                startRecording()
            } else if state == .recording || state == .connecting {
                isToggled = false
                stopRecording()
            }
        }
    }

    func handleHotkeyRelease() {
        dbg("handleHotkeyRelease state=\(state) mode=\(settings.hotkeyMode)")
        guard settings.hotkeyMode == .hold else { return }
        stopRecording()
    }
}
