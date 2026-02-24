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
        HStack(alignment: isMultiLine ? .top : .center, spacing: 12) {
            micIndicator
                .padding(.top, isMultiLine ? 2 : 0)

            contentText
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity)
        .background(
            RoundedRectangle(cornerRadius: 28, style: .continuous)
                .fill(.regularMaterial)
        )
        .background(.clear)
    }

    private var isMultiLine: Bool {
        !viewModel.displayText.isEmpty
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
        case .injected:   return "Done"
        case .error:      return ""
        }
    }
}

struct ModeSelectorView: View {
    private var settings = AppSettings.shared
    @State private var isPressed = false
    @State private var isHovered = false

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "wand.and.stars")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(isHovered ? .primary : .secondary)
            Text(settings.postProcessingMode.shortLabel)
                .font(.system(.subheadline, design: .rounded))
                .foregroundStyle(.primary)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
            Image(systemName: "chevron.up.chevron.down")
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(.tertiary)
                .opacity(isHovered ? 1 : 0)
        }
        .padding(.horizontal, 12)
        .frame(maxWidth: .infinity, minHeight: 56)
        .background(
            RoundedRectangle(cornerRadius: 28, style: .continuous)
                .fill(isPressed ? AnyShapeStyle(.quaternary) : isHovered ? AnyShapeStyle(.quinary.opacity(1.4)) : AnyShapeStyle(.regularMaterial))
        )
        .contentShape(RoundedRectangle(cornerRadius: 28, style: .continuous))
        .onHover { isHovered = $0 }
        .onLongPressGesture(minimumDuration: 0, maximumDistance: 50, pressing: { pressing in
            isPressed = pressing
        }, perform: {
            settings.postProcessingMode = settings.postProcessingMode.next
        })
        .animation(.easeInOut(duration: 0.12), value: isHovered)
        .animation(.easeInOut(duration: 0.08), value: isPressed)
    }
}

struct OverlayRootView: View {
    var viewModel: OverlayViewModel

    private var showModeSelector: Bool {
        switch viewModel.state {
        case .idle, .error: return false
        case .recording, .processing, .injected: return true
        }
    }

    var body: some View {
        HStack(alignment: .center, spacing: 8) {
            OverlayView(viewModel: viewModel)
            ModeSelectorView()
                .frame(width: 140)
                .opacity(showModeSelector ? 1 : 0)
                .allowsHitTesting(showModeSelector)
                .animation(.easeInOut(duration: 0.15), value: showModeSelector)
        }
        .background(.clear)
    }
}
