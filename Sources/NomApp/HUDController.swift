import AppKit
import SwiftUI
import NomCore

@MainActor
final class HUDController {
    private var panels: [HUDPanel] = []
    private var hideTask: Task<Void, Never>?

    func show(space: SpaceInfo) {
        hideTask?.cancel()
        dismissAll()

        for screen in NSScreen.screens {
            let panel = HUDPanel(screen: screen)

            let hostingView = NSHostingView(
                rootView: HUDView(
                    spaceIndex: space.index,
                    spaceName: space.displayName
                )
            )
            // Let SwiftUI size the content intrinsically
            hostingView.translatesAutoresizingMaskIntoConstraints = false
            panel.contentView?.addSubview(hostingView)
            if let contentView = panel.contentView {
                NSLayoutConstraint.activate([
                    hostingView.centerXAnchor.constraint(equalTo: contentView.centerXAnchor),
                    hostingView.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),
                ])
            }

            // Start above visible area (slide down entry)
            let restY = panel.frame.origin.y
            panel.setFrameOrigin(NSPoint(x: panel.frame.origin.x, y: restY + 30))
            panel.alphaValue = 0
            panel.orderFrontRegardless()

            // Animate in: slide down + fade in
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.35
                ctx.timingFunction = CAMediaTimingFunction(controlPoints: 0.2, 1.0, 0.3, 1.0)
                panel.animator().setFrameOrigin(NSPoint(x: panel.frame.origin.x, y: restY))
                panel.animator().alphaValue = 1
            }

            panels.append(panel)
        }

        hideTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(1.5))
            guard !Task.isCancelled else { return }
            slideOutAll()
        }
    }

    private func slideOutAll() {
        let panelsToAnimate = panels
        panels = []

        for panel in panelsToAnimate {
            let targetY = panel.frame.origin.y + 20

            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.25
                ctx.timingFunction = CAMediaTimingFunction(controlPoints: 0.4, 0.0, 1.0, 1.0)
                panel.animator().setFrameOrigin(NSPoint(x: panel.frame.origin.x, y: targetY))
                panel.animator().alphaValue = 0
            }
        }

        Task { @MainActor in
            try? await Task.sleep(for: .seconds(0.3))
            for panel in panelsToAnimate {
                panel.close()
            }
        }
    }

    private func dismissAll() {
        for panel in panels {
            panel.close()
        }
        panels = []
    }
}
