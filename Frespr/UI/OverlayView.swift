import SwiftUI

@Observable
final class OverlayViewModel {
    var state: RecordingState = .idle
    var interimText: String = ""
    var finalText: String = ""

    enum RecordingState {
        case idle
        case recording
        case processing
    }

    var displayText: String {
        if !finalText.isEmpty { return finalText }
        return interimText
    }

    var isFinal: Bool { !finalText.isEmpty }

    func reset() {
        state = .idle
        interimText = ""
        finalText = ""
    }
}

struct OverlayView: View {
    var viewModel: OverlayViewModel

    var body: some View {
        HStack(spacing: 12) {
            // Mic indicator
            micIndicator

            // Transcript text
            VStack(alignment: .leading, spacing: 2) {
                if viewModel.displayText.isEmpty {
                    Text(placeholderText)
                        .font(.system(.body, design: .rounded))
                        .foregroundStyle(.secondary)
                } else {
                    Text(viewModel.displayText)
                        .font(.system(.body, design: .rounded))
                        .foregroundStyle(viewModel.isFinal ? .primary : .secondary)
                        .lineLimit(3)
                        .animation(.easeInOut(duration: 0.1), value: viewModel.displayText)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(.regularMaterial)
                .shadow(color: .black.opacity(0.2), radius: 12, x: 0, y: 4)
        )
    }

    @ViewBuilder
    private var micIndicator: some View {
        ZStack {
            Circle()
                .fill(indicatorColor.opacity(0.2))
                .frame(width: 40, height: 40)

            Image(systemName: indicatorIcon)
                .font(.system(size: 18, weight: .medium))
                .foregroundStyle(indicatorColor)
                .symbolEffect(.pulse, isActive: viewModel.state == .recording)
        }
    }

    private var indicatorColor: Color {
        switch viewModel.state {
        case .idle: return .secondary
        case .recording: return .red
        case .processing: return .orange
        }
    }

    private var indicatorIcon: String {
        switch viewModel.state {
        case .idle: return "mic"
        case .recording: return "mic.fill"
        case .processing: return "waveform"
        }
    }

    private var placeholderText: String {
        switch viewModel.state {
        case .idle: return "Listening…"
        case .recording: return "Speak now…"
        case .processing: return "Processing…"
        }
    }
}

