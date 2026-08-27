import AppKit
import SwiftUI

final class OverlayWindow: NSPanel {
    private let viewModel: OverlayViewModel
    private var hideWorkItem: DispatchWorkItem?
    var hasPendingHide: Bool { hideWorkItem != nil }

    private static let width: CGFloat = 680
    private static let minHeight: CGFloat = 52
    private static let maxHeight: CGFloat = 280

    init(viewModel: OverlayViewModel) {
        self.viewModel = viewModel

        let mouseLocation = NSEvent.mouseLocation
        let activeScreen = NSScreen.screens.first(where: { NSMouseInRect(mouseLocation, $0.frame, false) }) ?? NSScreen.main
        let screenRect = activeScreen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let w = OverlayWindow.width
        let h = OverlayWindow.minHeight
        let x = screenRect.midX - w / 2
        let y = screenRect.minY + 48

        super.init(
            contentRect: NSRect(x: x, y: y, width: w, height: h),
            styleMask: [.nonactivatingPanel, .borderless],
            backing: .buffered,
            defer: false
        )

        self.isFloatingPanel = true
        self.level = .floating
        self.isOpaque = false
        self.backgroundColor = .clear
        self.hasShadow = true
        self.isMovableByWindowBackground = false
        self.collectionBehavior = [.moveToActiveSpace, .ignoresCycle]
        self.hidesOnDeactivate = false
        self.becomesKeyOnlyIfNeeded = true
        self.alphaValue = 0

        let hosting = ClickableHostingView(rootView: OverlayRootView(viewModel: viewModel))
        hosting.sizingOptions = [.intrinsicContentSize]
        hosting.wantsLayer = true
        hosting.layer?.backgroundColor = .clear
        hosting.layer?.isOpaque = false
        self.contentView = hosting

        // Poll height every ~50ms while visible — NSHostingView updates fittingSize
        // asynchronously; polling is more reliable than KVO across macOS versions.
        Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
            guard let self, self.alphaValue > 0 else { return }
            let desired = hosting.fittingSize.height
            if desired > 1 && abs(desired - self.frame.height) > 1 {
                self.fitToContent(intrinsicHeight: desired)
            }
        }
    }

    // MARK: - Show / Hide

    func show() {
        hideWorkItem?.cancel()
        hideWorkItem = nil
        // Only reposition when not already visible — avoids jumping when
        // show() is called again mid-session.
        if self.alphaValue == 0 {
            reposition()
        }
        self.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.18
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            self.animator().alphaValue = 1.0
        }
    }

    func showError(_ message: String, duration: TimeInterval = 4.0) {
        viewModel.errorMessage = message
        viewModel.state = .error
        show()
        scheduleHide(after: duration)
    }

    /// Marks the transcript as delivered and hides the overlay immediately.
    ///
    /// Previously held the overlay for 1.5s to flash an "injected" confirmation.
    /// That hold was the perceived lag on stop: the text lands in the target app
    /// essentially instantly, so the overlay stayed on screen well after the user
    /// could already see the result — reading as the app being slow rather than as
    /// confirmation. The app itself is the confirmation.
    ///
    /// No hold replaces it: an AX-vs-pasteboard distinction tracks which API was
    /// used, not whether delivery failed, and the fallback is the normal path in most
    /// apps — so holding on it re-showed the overlay on nearly every dictation. Real
    /// errors surface via showError(), which has its own display duration.
    func flashInjected() {
        viewModel.state = .injected
        hide()
    }

    func hide() {
        hideWorkItem?.cancel()
        hideWorkItem = nil
        fadeOut()
    }

    func hideIfIdle() {
        guard hideWorkItem == nil else { return }
        fadeOut()
    }

    // MARK: - Private

    private func reposition() {
        let mouseLocation = NSEvent.mouseLocation
        let screen = NSScreen.screens.first(where: { NSMouseInRect(mouseLocation, $0.frame, false) }) ?? NSScreen.main
        guard let screen else { return }
        let screenRect = screen.visibleFrame
        let w = OverlayWindow.width
        let h = max(OverlayWindow.minHeight, min(OverlayWindow.maxHeight, self.frame.height))
        let x = screenRect.midX - w / 2
        let y = screenRect.minY + 48
        self.setFrame(NSRect(x: x, y: y, width: w, height: h), display: true)
    }

    private func fitToContent(intrinsicHeight: CGFloat) {
        let newH = max(OverlayWindow.minHeight, min(OverlayWindow.maxHeight, intrinsicHeight))
        let currentFrame = self.frame
        // Keep the bottom edge fixed; grow upward.
        let newFrame = NSRect(x: currentFrame.minX, y: currentFrame.minY, width: OverlayWindow.width, height: newH)
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.15
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            self.animator().setFrame(newFrame, display: true)
        }
    }

    private func scheduleHide(after delay: TimeInterval) {
        let work = DispatchWorkItem { [weak self] in
            self?.fadeOut()
            self?.viewModel.reset()
        }
        hideWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    private func fadeOut() {
        // Hides immediately — no fade.
        //
        // Previously a 0.25s eased alpha animation. On hotkey-stop with post-processing
        // off, the transcript is injected almost instantly, so the overlay lingering
        // through a quarter-second fade read as the app being slow to respond. Dropping
        // the animation makes the stop feel instant.
        //
        // alphaValue is reset to 0 before orderOut (rather than relying on orderOut
        // alone) so the next show() starts from a known state — show() checks
        // `alphaValue == 0` to decide whether to animate in.
        alphaValue = 0
        orderOut(nil)
    }

    override var canBecomeKey: Bool { true }
    override var acceptsFirstResponder: Bool { true }
}

/// NSHostingView subclass that accepts first-mouse so SwiftUI buttons fire
/// on a non-activating panel without requiring the window to become key first.
final class ClickableHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}
