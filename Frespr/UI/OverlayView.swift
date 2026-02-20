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
        HStack(alignment: .top, spacing: 12) {
            micIndicator
                .padding(.top, 2)  // align icon with first line of text

            contentText
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

    // MARK: - Content

    @ViewBuilder
    private var contentText: some View {
        switch viewModel.state {
        case .error:
            Text(viewModel.errorMessage)
                .font(.system(.body, design: .rounded))
                .foregroundStyle(.primary)
                .fixedSize(horizontal: false, vertical: true)

        case .injected:
            Text("Injected")
                .font(.system(.body, design: .rounded).weight(.medium))
                .foregroundStyle(.green)

        default:
            if viewModel.displayText.isEmpty {
                Text(placeholderText)
                    .font(.system(.body, design: .rounded))
                    .foregroundStyle(.secondary)
            } else {
                ScrollViewReader { proxy in
                    ScrollView(.vertical, showsIndicators: false) {
                        Text(viewModel.displayText)
                            .font(.system(.body, design: .rounded))
                            .foregroundStyle(viewModel.isFinal ? .primary : .secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .fixedSize(horizontal: false, vertical: true)
                            .id("text")
                    }
                    .frame(maxHeight: 160)  // ~6 lines before scrolling kicks in
                    .onChange(of: viewModel.displayText) { _, _ in
                        withAnimation(.easeOut(duration: 0.15)) {
                            proxy.scrollTo("text", anchor: .bottom)
                        }
                    }
                }
            }
        }
    }

    // MARK: - Mic indicator

    @ViewBuilder
    private var micIndicator: some View {
        ZStack {
            Circle()
                .fill(indicatorColor.opacity(0.15))
                .frame(width: 36, height: 36)

            Image(systemName: indicatorIcon)
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(indicatorColor)
                .symbolEffect(.pulse, isActive: viewModel.state == .recording)
                .contentTransition(.symbolEffect(.replace))
        }
    }

    // MARK: - Computed

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
