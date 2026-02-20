import AppKit
import SwiftUI

final class OverlayWindow: NSPanel {
    private var hostingView: NSHostingView<OverlayView>?
    private let viewModel: OverlayViewModel

    init(viewModel: OverlayViewModel) {
        self.viewModel = viewModel

        let screenRect = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let width: CGFloat = 480
        let height: CGFloat = 100
        let x = screenRect.midX - width / 2
        let y = screenRect.minY + 40  // 40pt from bottom

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

        let overlayView = OverlayView(viewModel: viewModel)
        let hosting = NSHostingView(rootView: overlayView)
        hosting.frame = contentRect
        self.contentView = hosting
        hostingView = hosting
    }

    func show() {
        self.orderFrontRegardless()
        // Reposition each time in case screen changed
        if let screen = NSScreen.main {
            let screenRect = screen.visibleFrame
            let width: CGFloat = 480
            let height: CGFloat = 100
            let x = screenRect.midX - width / 2
            let y = screenRect.minY + 40
            self.setFrame(NSRect(x: x, y: y, width: width, height: height), display: true)
        }
    }

    func hide() {
        self.orderOut(nil)
    }
}
