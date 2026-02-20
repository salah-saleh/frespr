import AVFoundation
import Foundation

enum AudioCaptureError: Error, LocalizedError {
    case noInputDevice
    case formatConversionFailed
    case engineStartFailed(Error)

    var errorDescription: String? {
        switch self {
        case .noInputDevice: return "No microphone input device found."
        case .formatConversionFailed: return "Failed to create audio format converter."
        case .engineStartFailed(let e): return "Audio engine failed to start: \(e.localizedDescription)"
        }
    }
}

final class AudioCaptureEngine {
    var onAudioChunk: ((Data) -> Void)?  // Called with 16kHz Int16 PCM chunks

    private let engine = AVAudioEngine()
    private var converter: AVAudioConverter?
    private var isRunning = false

    // Target: 16kHz, mono, Int16
    private let targetFormat = AVAudioFormat(
        commonFormat: .pcmFormatInt16,
        sampleRate: 16000,
        channels: 1,
        interleaved: true
    )!

    // Chunk size: ~100ms at 16kHz = 1600 samples = 3200 bytes
    private let chunkSampleCount: AVAudioFrameCount = 1600

    func start() throws {
        guard !isRunning else { return }
        dbg("AudioCaptureEngine.start()")

        let inputNode = engine.inputNode
        let inputFormat = inputNode.outputFormat(forBus: 0)
        dbg("input format: \(inputFormat.sampleRate)Hz ch=\(inputFormat.channelCount)")

        guard let targetFormat = AVAudioFormat(
            commonFormat: .pcmFormatInt16,
            sampleRate: 16000,
            channels: 1,
            interleaved: true
        ) else {
            throw AudioCaptureError.formatConversionFailed
        }

        guard let converter = AVAudioConverter(from: inputFormat, to: targetFormat) else {
            throw AudioCaptureError.formatConversionFailed
        }
        self.converter = converter

        // Buffer to accumulate converted samples
        var accumulator = Data()
        let bytesPerChunk = Int(chunkSampleCount) * 2  // Int16 = 2 bytes

        inputNode.installTap(onBus: 0, bufferSize: 4096, format: inputFormat) { [weak self] buffer, _ in
            guard let self = self, let converter = self.converter else { return }

            // Compute output frame count
            let ratio = targetFormat.sampleRate / inputFormat.sampleRate
            let outputFrameCount = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 1

            guard let outputBuffer = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: outputFrameCount) else { return }

            var error: NSError?
            var inputConsumed = false

            let status = converter.convert(to: outputBuffer, error: &error) { _, outStatus in
                if inputConsumed {
                    outStatus.pointee = .noDataNow
                    return nil
                }
                outStatus.pointee = .haveData
                inputConsumed = true
                return buffer
            }

            guard status != .error, let channelData = outputBuffer.int16ChannelData else { return }

            let frameCount = Int(outputBuffer.frameLength)
            let rawPointer = UnsafeRawPointer(channelData[0])
            let data = Data(bytes: rawPointer, count: frameCount * 2)
            accumulator.append(data)

            // Emit full chunks
            var chunksEmitted = 0
            while accumulator.count >= bytesPerChunk {
                let chunk = accumulator.prefix(bytesPerChunk)
                accumulator.removeFirst(bytesPerChunk)
                self.onAudioChunk?(Data(chunk))
                chunksEmitted += 1
            }
            if chunksEmitted > 0 { dbg("audio: emitted \(chunksEmitted) chunk(s)") }
        }

        do {
            try engine.start()
            isRunning = true
            dbg("AudioCaptureEngine started OK")
        } catch {
            inputNode.removeTap(onBus: 0)
            dbg("AudioCaptureEngine start error: \(error)")
            throw AudioCaptureError.engineStartFailed(error)
        }
    }

    func stop() {
        guard isRunning else { return }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        converter = nil
        isRunning = false
    }
}
