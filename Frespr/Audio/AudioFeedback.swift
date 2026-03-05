import AVFoundation

/// Plays short synthesized tones for recording start/stop/success/error feedback.
/// Uses AVAudioEngine to generate tones without requiring bundled audio files.
final class AudioFeedback {
    static let shared = AudioFeedback()

    private let engine = AVAudioEngine()
    private let playerNode = AVAudioPlayerNode()
    private let format: AVAudioFormat

    private init() {
        let sampleRate = 44100.0
        format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1)!
        engine.attach(playerNode)
        engine.connect(playerNode, to: engine.mainMixerNode, format: format)
    }

    /// Soft ascending two-tone pip — confirms recording started.
    func playStart() {
        guard AppSettings.shared.soundFeedbackEnabled else { return }
        playTones([(600, 0.06), (800, 0.06)], volume: 0.15)
    }

    /// Soft descending pip — confirms recording stopped.
    func playStop() {
        guard AppSettings.shared.soundFeedbackEnabled else { return }
        playTones([(800, 0.06), (600, 0.06)], volume: 0.15)
    }

    /// Quick bright chime — text successfully injected.
    func playSuccess() {
        guard AppSettings.shared.soundFeedbackEnabled else { return }
        playTones([(880, 0.07), (1100, 0.09)], volume: 0.12)
    }

    /// Low buzz — something went wrong.
    func playError() {
        guard AppSettings.shared.soundFeedbackEnabled else { return }
        playTones([(280, 0.12), (220, 0.14)], volume: 0.18)
    }

    // MARK: - Tone generation

    private func playTones(_ tones: [(hz: Double, duration: Double)], volume: Float) {
        let sampleRate = format.sampleRate
        var allSamples: [Float] = []

        for tone in tones {
            let count = Int(sampleRate * tone.duration)
            let fadeLen = min(count / 4, 200) // smooth fade in/out to avoid clicks
            for i in 0..<count {
                let t = Double(i) / sampleRate
                var sample = Float(sin(2.0 * .pi * tone.hz * t)) * volume

                // Fade in
                if i < fadeLen {
                    sample *= Float(i) / Float(fadeLen)
                }
                // Fade out
                if i > count - fadeLen {
                    sample *= Float(count - i) / Float(fadeLen)
                }
                allSamples.append(sample)
            }
        }

        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(allSamples.count)) else { return }
        buffer.frameLength = AVAudioFrameCount(allSamples.count)
        let channelData = buffer.floatChannelData![0]
        for i in 0..<allSamples.count {
            channelData[i] = allSamples[i]
        }

        do {
            if !engine.isRunning { try engine.start() }
            playerNode.stop()
            playerNode.scheduleBuffer(buffer) { [weak self] in
                // Stop engine after playback to release audio resources
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                    self?.engine.stop()
                }
            }
            playerNode.play()
        } catch {
            dbg("AudioFeedback play error: \(error)")
        }
    }
}
