import SwiftUI

@Observable
final class OverlayViewModel {
    var state: RecordingState = .idle
    var interimText: String = ""
    var finalText: String = ""
    var errorMessage: String = ""

    enum RecordingState {
        case idle
        case recording
        case processing
        case injected   // brief success flash
        case error      // non-blocking toast
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
        errorMessage = ""
    }
}

struct OverlayView: View {
    var viewModel: OverlayViewModel

    var body: some View {
        HStack(spacing: 12) {
            micIndicator

            VStack(alignment: .leading, spacing: 2) {
                switch viewModel.state {
                case .error:
                    Text(viewModel.errorMessage)
                        .font(.system(.body, design: .rounded))
                        .foregroundStyle(.primary)
                        .lineLimit(3)
                case .injected:
                    Text("Injected")
                        .font(.system(.body, design: .rounded).weight(.medium))
                        .foregroundStyle(.primary)
                default:
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
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(backgroundMaterial)
                .shadow(color: .black.opacity(0.2), radius: 12, x: 0, y: 4)
        )
    }

    // MARK: - Subviews

    @ViewBuilder
    private var micIndicator: some View {
        ZStack {
            Circle()
                .fill(indicatorColor.opacity(0.15))
                .frame(width: 40, height: 40)

            Image(systemName: indicatorIcon)
                .font(.system(size: 18, weight: .medium))
                .foregroundStyle(indicatorColor)
                .symbolEffect(.pulse, isActive: viewModel.state == .recording)
                .contentTransition(.symbolEffect(.replace))
        }
    }

    // MARK: - Computed properties

    private var backgroundMaterial: some ShapeStyle {
        switch viewModel.state {
        case .error: return AnyShapeStyle(.regularMaterial)
        default: return AnyShapeStyle(.regularMaterial)
        }
    }

    private var indicatorColor: Color {
        switch viewModel.state {
        case .idle:       return .secondary
        case .recording:  return .red
        case .processing: return .orange
        case .injected:   return .green
        case .error:      return .red
        }
    }

    private var indicatorIcon: String {
        switch viewModel.state {
        case .idle:       return "mic"
        case .recording:  return "mic.fill"
        case .processing: return "waveform"
        case .injected:   return "checkmark"
        case .error:      return "exclamationmark.triangle.fill"
        }
    }

    private var placeholderText: String {
        switch viewModel.state {
        case .idle:       return "Listening…"
        case .recording:  return "Speak now…"
        case .processing: return "Processing…"
        case .injected:   return "Injected"
        case .error:      return ""
        }
    }
}
