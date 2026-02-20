import AppKit
import SwiftUI

final class OverlayWindow: NSPanel {
    private var hostingView: NSHostingView<OverlayView>?
    private let viewModel: OverlayViewModel
    private var hideWorkItem: DispatchWorkItem?

    init(viewModel: OverlayViewModel) {
        self.viewModel = viewModel

        let screenRect = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let width: CGFloat = 480
        let height: CGFloat = 80
        let x = screenRect.midX - width / 2
        let y = screenRect.minY + 48

        let contentRect = NSRect(x: x, y: y, width: width, height: height)

        super.init(
            contentRect: contentRect,
            styleMask: [.nonactivatingPanel, .borderless, .hudWindow],
            backing: .buffered,
            defer: false
        )

        self.isFloatingPanel = true
        self.level = .floating
        self.isOpaque = false
        self.backgroundColor = .clear
        self.hasShadow = true
        self.isMovableByWindowBackground = false
        self.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        self.hidesOnDeactivate = false
        self.alphaValue = 0

        let overlayView = OverlayView(viewModel: viewModel)
        let hosting = NSHostingView(rootView: overlayView)
        hosting.frame = NSRect(origin: .zero, size: contentRect.size)
        self.contentView = hosting
        hostingView = hosting
    }

    // MARK: - Show / Hide

    func show() {
        // Cancel any pending auto-hide
        hideWorkItem?.cancel()
        hideWorkItem = nil

        reposition()
        self.orderFrontRegardless()

        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.18
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            self.animator().alphaValue = 1.0
        }
    }

    /// Show a non-blocking error toast that auto-dismisses after `duration` seconds.
    func showError(_ message: String, duration: TimeInterval = 4.0) {
        viewModel.errorMessage = message
        viewModel.state = .error
        show()
        scheduleHide(after: duration)
    }

    /// Flash a brief "injected" success indicator, then fade out.
    func flashInjected() {
        viewModel.state = .injected
        show()
        scheduleHide(after: 1.2)
    }

    func hide() {
        hideWorkItem?.cancel()
        hideWorkItem = nil
        fadeOut()
    }

    // MARK: - Private

    private func reposition() {
        guard let screen = NSScreen.main else { return }
        let screenRect = screen.visibleFrame
        let width: CGFloat = 480
        let height: CGFloat = 80
        let x = screenRect.midX - width / 2
        let y = screenRect.minY + 48
        self.setFrame(NSRect(x: x, y: y, width: width, height: height), display: true)
    }

    private func scheduleHide(after delay: TimeInterval) {
        let work = DispatchWorkItem { [weak self] in self?.fadeOut() }
        hideWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    private func fadeOut() {
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.25
            ctx.timingFunction = CAMediaTimingFunction(name: .easeIn)
            self.animator().alphaValue = 0
        }, completionHandler: {
            self.orderOut(nil)
        })
    }
}
