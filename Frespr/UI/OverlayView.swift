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
        case injected
        case error
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

// MARK: - Brand colours

private extension Color {
    static let brand1     = Color(red: 0.357, green: 0.612, blue: 0.965) // #5b9cf6
    static let brand2     = Color(red: 0.545, green: 0.435, blue: 0.973) // #8b6ff8
    static let brand3     = Color(red: 0.212, green: 0.831, blue: 0.941) // #36d4f0
    static let brandError = Color(red: 1.0,   green: 0.384, blue: 0.573) // #f06292
    static let overlayBg  = Color(red: 0.055, green: 0.082, blue: 0.133) // #0e1522
    static let overlayBdr = Color(red: 0.133, green: 0.188, blue: 0.29)  // #223048
    static let overlayBd2 = Color(red: 0.172, green: 0.247, blue: 0.369) // #2c3f5e
}

private let brandGrad = LinearGradient(
    colors: [.brand1, .brand2, .brand3],
    startPoint: .leading, endPoint: .trailing
)
private let brandGradV = LinearGradient(
    colors: [.brand1, .brand2],
    startPoint: .top, endPoint: .bottom
)

// MARK: - OverlayView

struct OverlayView: View {
    var viewModel: OverlayViewModel

    private var hasContent: Bool {
        !viewModel.displayText.isEmpty || viewModel.state == .error
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // ── Header row ──────────────────────────────────────────
            HStack(alignment: .center, spacing: 10) {
                micIndicator
                statusLabel
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 16)
            .padding(.top, 12)
            .padding(.bottom, hasContent ? 9 : 12)

            // ── Transcript — always in layout, zero-height when empty ─
            if hasContent {
                Rectangle()
                    .fill(Color.overlayBdr)
                    .frame(height: 1)
                    .padding(.horizontal, 14)

                transcriptBody
                    .padding(.horizontal, 16)
                    .padding(.top, 9)
                    .padding(.bottom, 12)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(overlayBackground)
    }

    // MARK: - Background

    private var overlayBackground: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(Color.overlayBg.opacity(0.97))

            // shimmer top line
            VStack(spacing: 0) {
                LinearGradient(
                    colors: [.clear, .brand1.opacity(0.5), .brand2.opacity(0.4), .clear],
                    startPoint: .leading, endPoint: .trailing
                )
                .frame(height: 1)
                Spacer()
            }
            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))

            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(Color.overlayBdr, lineWidth: 1)
        }
    }

    // MARK: - Status label

    @ViewBuilder
    private var statusLabel: some View {
        switch viewModel.state {
        case .idle:
            Text("Listening…")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Color.brand3)

        case .recording:
            HStack(spacing: 7) {
                Text("RECORDING")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(Color.brand3)
                    .kerning(0.6)
                WaveformBars()
            }

        case .processing:
            Text("PROCESSING")
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(Color.brand1)
                .kerning(0.6)

        case .injected:
            HStack(spacing: 5) {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Color.brand3)
                Text("INJECTED")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(Color.brand3)
                    .kerning(0.6)
            }

        case .error:
            HStack(spacing: 5) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 12))
                    .foregroundStyle(Color.brandError)
                Text("ERROR")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(Color.brandError)
                    .kerning(0.6)
            }
        }
    }

    // MARK: - Transcript body

    @ViewBuilder
    private var transcriptBody: some View {
        if viewModel.state == .error {
            Text(viewModel.errorMessage)
                .font(.system(size: 13.5))
                .foregroundStyle(Color.brandError.opacity(0.85))
                .fixedSize(horizontal: false, vertical: true)
        } else {
            ScrollViewReader { proxy in
                ScrollView(.vertical, showsIndicators: false) {
                    Text(viewModel.displayText)
                        .font(.system(size: 14.5))
                        .foregroundStyle(viewModel.isFinal ? Color(white: 0.93) : Color(white: 0.6))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .fixedSize(horizontal: false, vertical: true)
                        .id("text")
                }
                .frame(maxHeight: 160)
                .onChange(of: viewModel.displayText) { _, _ in
                    withAnimation(.easeOut(duration: 0.15)) {
                        proxy.scrollTo("text", anchor: .bottom)
                    }
                }
            }
        }
    }

    // MARK: - Mic indicator

    private var micIndicator: some View {
        ZStack {
            Circle()
                .fill(indicatorGlow.opacity(viewModel.state == .recording ? 0.2 : 0.12))
                .frame(width: 32, height: 32)

            Circle()
                .strokeBorder(indicatorGlow.opacity(0.35), lineWidth: 1)
                .frame(width: 30, height: 30)

            Image(systemName: indicatorIcon)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(indicatorForeground)
                .symbolEffect(.pulse, isActive: viewModel.state == .recording)
                .contentTransition(.symbolEffect(.replace))
        }
        .frame(width: 30, height: 30)
    }

    private var indicatorGlow: Color {
        switch viewModel.state {
        case .idle, .recording, .injected: return .brand3
        case .processing:                  return .brand1
        case .error:                       return .brandError
        }
    }

    private var indicatorForeground: AnyShapeStyle {
        switch viewModel.state {
        case .idle, .recording, .injected: return AnyShapeStyle(brandGrad)
        case .processing:                  return AnyShapeStyle(Color.brand1)
        case .error:                       return AnyShapeStyle(Color.brandError)
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
}

// MARK: - Animated waveform bars

private struct WaveformBars: View {
    @State private var animating = false

    private let heights: [CGFloat] = [4, 8, 12, 7, 14, 10, 6, 13, 9, 11, 7, 5]
    private let delays:  [Double]  = [0, 0.1, 0.2, 0.05, 0.15, 0.25, 0.08, 0.18, 0.03, 0.12, 0.22, 0.07]

    var body: some View {
        HStack(alignment: .center, spacing: 2) {
            ForEach(0..<heights.count, id: \.self) { i in
                RoundedRectangle(cornerRadius: 1.5)
                    .fill(brandGradV)
                    .frame(width: 2.5, height: animating ? heights[i] : 2)
                    .animation(
                        .easeInOut(duration: 0.42)
                            .repeatForever(autoreverses: true)
                            .delay(delays[i]),
                        value: animating
                    )
            }
        }
        .frame(height: 16)
        .onAppear { animating = true }
    }
}

// MARK: - ModeSelectorView

struct ModeSelectorView: View {
    private var settings = AppSettings.shared
    @State private var isPressed = false
    @State private var isHovered = false

    var body: some View {
        HStack(spacing: 7) {
            Image(systemName: "wand.and.stars")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(isHovered ? AnyShapeStyle(brandGrad) : AnyShapeStyle(Color(white: 0.45)))
            Text(settings.postProcessingMode.shortLabel)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Color(white: isHovered ? 0.9 : 0.7))
                .lineLimit(1)
                .minimumScaleFactor(0.8)
            if isHovered {
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(Color(white: 0.4))
            }
        }
        .padding(.horizontal, 14)
        .frame(maxWidth: .infinity, minHeight: 52)
        .background(modeBackground)
        .contentShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .onHover { isHovered = $0 }
        .onLongPressGesture(minimumDuration: 0, maximumDistance: 50, pressing: { pressing in
            isPressed = pressing
        }, perform: {
            settings.postProcessingMode = settings.postProcessingMode.next
        })
        .animation(.easeInOut(duration: 0.12), value: isHovered)
        .animation(.easeInOut(duration: 0.08), value: isPressed)
    }

    private var modeBackground: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(Color.overlayBg.opacity(0.97))
            VStack(spacing: 0) {
                LinearGradient(
                    colors: [.clear, .brand2.opacity(0.4), .brand3.opacity(0.35), .clear],
                    startPoint: .leading, endPoint: .trailing
                )
                .frame(height: 1)
                Spacer()
            }
            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(isHovered ? Color.overlayBd2 : Color.overlayBdr, lineWidth: 1)
        }
    }
}

// MARK: - OverlayRootView

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
