import AppKit
import SwiftUI
import NomCore

/// A HUD-styled card with a focused text field, shown on a freshly created
/// desktop so it can be named without reopening the menu. Return commits,
/// Escape (or clicking elsewhere) leaves the desktop unnamed.
@MainActor
final class RenamePromptController: NSObject, NSWindowDelegate {
    private var panel: RenamePanel?
    private var onFinish: ((String?) -> Void)?

    /// Show the card centered at the top of the screen that hosts `space`.
    /// `onCommit` receives the trimmed name, or nil when the user cancelled.
    func show(for space: SpaceInfo, onCommit: @escaping (String?) -> Void) {
        dismiss(result: nil)

        let screen = screen(forDisplayId: space.displayId) ?? NSScreen.main ?? NSScreen.screens[0]
        let panel = RenamePanel(screen: screen)
        panel.delegate = self
        onFinish = onCommit

        let view = RenameView(
            spaceIndex: space.index,
            onCommit: { [weak self] name in self?.dismiss(result: name) },
            onCancel: { [weak self] in self?.dismiss(result: nil) }
        )
        let hostingView = NSHostingView(rootView: view)
        hostingView.translatesAutoresizingMaskIntoConstraints = false
        panel.contentView?.addSubview(hostingView)
        if let contentView = panel.contentView {
            NSLayoutConstraint.activate([
                hostingView.centerXAnchor.constraint(equalTo: contentView.centerXAnchor),
                hostingView.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),
            ])
        }
        panel.fit(contentSize: hostingView.fittingSize, on: screen)
        panel.alphaValue = 0
        // Non-activating: the panel takes key status (and typing) without
        // bringing nom forward, so the previous app keeps its place.
        panel.makeKeyAndOrderFront(nil)
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.2
            panel.animator().alphaValue = 1
        }
        self.panel = panel
    }

    /// Called only when the user finished (commit or cancel). `onFinish`
    /// fires exactly once per prompt.
    private func dismiss(result: String?) {
        guard let panel else { return }
        self.panel = nil
        let finish = onFinish
        onFinish = nil
        panel.delegate = nil
        panel.close()
        finish?(result)
    }

    /// The user clicked somewhere else — treat as cancel so a stale card
    /// never lingers.
    func windowDidResignKey(_ notification: Notification) {
        dismiss(result: nil)
    }

    private func screen(forDisplayId displayId: String) -> NSScreen? {
        guard let target = Displays.directDisplayID(forDisplayId: displayId) else { return nil }
        let key = NSDeviceDescriptionKey("NSScreenNumber")
        return NSScreen.screens.first { ($0.deviceDescription[key] as? CGDirectDisplayID) == target }
    }
}

final class RenamePanel: NSPanel {
    init(screen: NSScreen) {
        super.init(
            contentRect: NSRect(x: screen.frame.midX - 300, y: screen.visibleFrame.maxY - 172, width: 600, height: 160),
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
        hidesOnDeactivate = false
        animationBehavior = .none
    }

    // Borderless panels refuse key status by default; the text field needs it.
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

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

struct RenameView: View {
    let spaceIndex: Int
    let onCommit: (String?) -> Void
    let onCancel: () -> Void

    @State private var text = ""
    @FocusState private var isFocused: Bool

    var body: some View {
        HStack(spacing: 16) {
            Text("\(spaceIndex)")
                .font(.system(size: 52, weight: .thin, design: .rounded))
                .foregroundStyle(.white.opacity(0.35))

            Circle()
                .fill(.white.opacity(0.2))
                .frame(width: 6, height: 6)

            TextField(
                "",
                text: $text,
                prompt: Text("Name this space").foregroundStyle(.white.opacity(0.3))
            )
            .textFieldStyle(.plain)
            .font(.system(size: 44, weight: .bold, design: .rounded))
            .foregroundStyle(.white.opacity(0.95))
            .frame(width: 440)
            .focused($isFocused)
            .onSubmit {
                let trimmed = text.trimmingCharacters(in: .whitespaces)
                onCommit(trimmed.isEmpty ? nil : trimmed)
            }
            .onExitCommand { onCancel() }
        }
        .padding(.vertical, 28)
        .padding(.horizontal, 48)
        .background {
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .fill(Color(white: 0.12))
        }
        .onAppear { isFocused = true }
    }
}
