import AppKit
import SwiftUI

final class OverlayWindow: NSPanel {
    private var hostingView: ClickableHostingView<OverlayRootView>?
    private let viewModel: OverlayViewModel
    private var hideWorkItem: DispatchWorkItem?
    var hasPendingHide: Bool { hideWorkItem != nil }
    private var sizeObservation: NSKeyValueObservation?

    private static let width: CGFloat = 568
    private static let minHeight: CGFloat = 48
    private static let maxHeight: CGFloat = 240

    init(viewModel: OverlayViewModel) {
        self.viewModel = viewModel

        let screenRect = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
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
        self.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        self.hidesOnDeactivate = false
        self.becomesKeyOnlyIfNeeded = true
        self.alphaValue = 0

        let hosting = ClickableHostingView(rootView: OverlayRootView(viewModel: viewModel))
        hosting.sizingOptions = .intrinsicContentSize
        hosting.frame = NSRect(x: 0, y: 0, width: w, height: h)
        hosting.wantsLayer = true
        hosting.layer?.backgroundColor = .clear
        hosting.layer?.isOpaque = false
        self.contentView = hosting
        hostingView = hosting

        sizeObservation = hosting.observe(\.intrinsicContentSize, options: [.new]) { [weak self] view, _ in
            let sz = view.intrinsicContentSize
            self?.fitToContent(width: sz.width > 0 ? sz.width : w)
        }
    }

    // MARK: - Show / Hide

    func show() {
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

    func showError(_ message: String, duration: TimeInterval = 4.0) {
        viewModel.errorMessage = message
        viewModel.state = .error
        show()
        scheduleHide(after: duration)
    }

    func flashInjected() {
        viewModel.state = .injected
        show()
        scheduleHide(after: 1.5)
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
        guard let screen = NSScreen.main else { return }
        let screenRect = screen.visibleFrame
        let w = OverlayWindow.width
        let h = max(OverlayWindow.minHeight, min(OverlayWindow.maxHeight, self.frame.height))
        let x = screenRect.midX - w / 2
        let y = screenRect.minY + 48
        self.setFrame(NSRect(x: x, y: y, width: w, height: h), display: true)
    }

    private func fitToContent(width: CGFloat) {
        guard let hosting = hostingView else { return }
        let desired = hosting.fittingSize.height
        let newH = max(OverlayWindow.minHeight, min(OverlayWindow.maxHeight, desired))
        let currentFrame = self.frame
        let newY = currentFrame.minY + currentFrame.height - newH
        let newFrame = NSRect(x: currentFrame.minX, y: newY, width: OverlayWindow.width, height: newH)
        self.setFrame(newFrame, display: true, animate: false)
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
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.25
            ctx.timingFunction = CAMediaTimingFunction(name: .easeIn)
            self.animator().alphaValue = 0
        }, completionHandler: {
            self.orderOut(nil)
        })
    }

    override var canBecomeKey: Bool { true }
    override var acceptsFirstResponder: Bool { true }
}

/// NSHostingView subclass that accepts first-mouse so SwiftUI buttons fire
/// on a non-activating panel without requiring the window to become key first.
final class ClickableHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}
