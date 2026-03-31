import AppKit
import SwiftUI
import NomCore

@MainActor
final class HUDController {
    private var panels: [(panel: HUDPanel, hostingView: NSHostingView<HUDView>)] = []
    private var hideTask: Task<Void, Never>?
    private var isVisible = false

    func show(space: SpaceInfo) {
        hideTask?.cancel()

        let newView = HUDView(spaceIndex: space.index, spaceName: space.displayName)

        if isVisible {
            // Panels already on screen — just swap the content
            for entry in panels {
                entry.hostingView.rootView = newView
            }
        } else {
            // Create fresh panels and animate in
            dismissAll()
            isVisible = true

            for screen in NSScreen.screens {
                let panel = HUDPanel(screen: screen)
                let hostingView = NSHostingView(rootView: newView)
                hostingView.translatesAutoresizingMaskIntoConstraints = false
                panel.contentView?.addSubview(hostingView)
                if let contentView = panel.contentView {
                    NSLayoutConstraint.activate([
                        hostingView.centerXAnchor.constraint(equalTo: contentView.centerXAnchor),
                        hostingView.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),
                    ])
                }

                let restY = panel.frame.origin.y
                panel.setFrameOrigin(NSPoint(x: panel.frame.origin.x, y: restY + 30))
                panel.alphaValue = 0
                panel.orderFrontRegardless()

                NSAnimationContext.runAnimationGroup { ctx in
                    ctx.duration = 0.35
                    ctx.timingFunction = CAMediaTimingFunction(controlPoints: 0.2, 1.0, 0.3, 1.0)
                    panel.animator().setFrameOrigin(NSPoint(x: panel.frame.origin.x, y: restY))
                    panel.animator().alphaValue = 1
                }

                panels.append((panel: panel, hostingView: hostingView))
            }
        }

        // Reset dismiss timer
        hideTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(1.5))
            guard !Task.isCancelled else { return }
            slideOutAll()
        }
    }

    private func slideOutAll() {
        let panelsToAnimate = panels
        panels = []
        isVisible = false

        for entry in panelsToAnimate {
            let targetY = entry.panel.frame.origin.y + 20

            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.25
                ctx.timingFunction = CAMediaTimingFunction(controlPoints: 0.4, 0.0, 1.0, 1.0)
                entry.panel.animator().setFrameOrigin(NSPoint(x: entry.panel.frame.origin.x, y: targetY))
                entry.panel.animator().alphaValue = 0
            }
        }

        Task { @MainActor in
            try? await Task.sleep(for: .seconds(0.3))
            for entry in panelsToAnimate {
                entry.panel.close()
            }
        }
    }

    private func dismissAll() {
        for entry in panels {
            entry.panel.close()
        }
        panels = []
        isVisible = false
    }
}
