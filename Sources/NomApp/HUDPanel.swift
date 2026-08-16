import AppKit

final class HUDPanel: NSPanel {
    init(screen: NSScreen) {
        // Start wide enough; content will size itself
        let width: CGFloat = 600
        let height: CGFloat = 160
        let origin = NSPoint(
            x: screen.frame.midX - width / 2,
            y: screen.visibleFrame.maxY - height - 12
        )

        super.init(
            contentRect: NSRect(origin: origin, size: NSSize(width: width, height: height)),
            styleMask: [.nonactivatingPanel, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )

        isFloatingPanel = true
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]

        titleVisibility = .hidden
        titlebarAppearsTransparent = true
        backgroundColor = .clear
        isOpaque = false
        hasShadow = false
        ignoresMouseEvents = true
        hidesOnDeactivate = false
        animationBehavior = .none
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    /// Resize to hug the HUD content (long space names widen the card),
    /// capped to the screen, re-centered at the top rest position.
    func fit(contentSize: NSSize, on screen: NSScreen) {
        let slack: CGFloat = 4
        let width = min(contentSize.width + slack, screen.frame.width - 40)
        let height = contentSize.height + slack
        let origin = NSPoint(
            x: screen.frame.midX - width / 2,
            y: screen.visibleFrame.maxY - height - 12
        )
        setFrame(NSRect(origin: origin, size: NSSize(width: width, height: height)), display: true)
    }
}
