import AppKit
import ApplicationServices

/// An opt-in integration test. The worker must be a separate process: calling
/// Accessibility against the fixture's own process does not exercise app IPC.
@main
@MainActor
enum WindowMoveSmokeTest {
    static func main() {
        let args = Array(CommandLine.arguments.dropFirst())
        let app = NSApplication.shared
        if args.first == "--worker" {
            guard args.count == 3, let pid = Int32(args[1]), let spaceID = Int(args[2]),
                  let target = SpaceReader.allSpaces().first(where: { $0.spaceId == spaceID })
            else { fail("Invalid worker arguments or missing destination") }
            app.setActivationPolicy(.prohibited)
            Task {
                let moved = await WindowMover.moveFocusedWindow(ofPid: pid, to: target)
                // Give any temporarily enabled shortcut time to be restored.
                try? await Task.sleep(for: .milliseconds(600))
                exit(moved ? 0 : 1)
            }
            app.run()
            return
        }
        let fullHeight = args.first == "--full-height"
        let desktopArgs = fullHeight ? Array(args.dropFirst()) : args
        guard desktopArgs.count <= 1, desktopArgs.isEmpty || Int(desktopArgs[0]) != nil else {
            fail("Usage: test-window-move.sh [--full-height] [destination-desktop-index]")
        }
        guard AXIsProcessTrusted() else { fail("Terminal needs Accessibility permission") }
        guard !CGEventSource.buttonState(.combinedSessionState, button: .left) else {
            fail("Release the mouse button before starting the test")
        }

        let initialSpaces = SpaceReader.currentSpaceIds()
        let initialApp = NSWorkspace.shared.frontmostApplication
        let initialPointer = CGEvent(source: nil)?.location
        app.setActivationPolicy(.regular)
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 600, height: 350),
                              styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.title = "nom disposable window move test"
        window.isReleasedWhenClosed = false
        window.center()
        if fullHeight {
            guard let visibleFrame = window.screen?.visibleFrame else { fail("Cannot identify the fixture's screen") }
            window.setFrame(CGRect(x: visibleFrame.midX - 300, y: visibleFrame.minY,
                                   width: 600, height: visibleFrame.height), display: false)
        }
        window.makeKeyAndOrderFront(nil)
        Task {
            try? await Task.sleep(for: .seconds(1))
            app.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
            try? await Task.sleep(for: .milliseconds(500))
            let originalFrame = window.frame
            var passed = await test(window: window, destinationIndex: desktopArgs.first.flatMap(Int.init), fullHeight: fullHeight)
            window.orderOut(nil)
            passed = await restore(initialSpaces: initialSpaces) && passed
            window.setFrame(originalFrame, display: false)
            initialApp?.activate(options: [])
            if let initialPointer { CGWarpMouseCursorPosition(initialPointer) }
            window.close()
            print(passed ? "PASS: window move round trip" : "FAIL: window move round trip")
            exit(passed ? 0 : 1)
        }
        app.run()
    }

    private static func test(window: NSWindow, destinationIndex: Int?, fullHeight: Bool) async -> Bool {
        let id = CGWindowID(window.windowNumber)
        let spaces = SpaceReader.allSpaces()
        guard let membership = SpaceReader.spaceIds(containingWindow: id), membership.count == 1,
              let original = spaces.first(where: { $0.spaceId == membership[0] })
        else { print("Cannot identify the fixture's source desktop"); return false }
        let candidates = spaces.filter { $0.displayId == original.displayId && $0.spaceId != original.spaceId }
        let destination: SpaceInfo?
        if let destinationIndex {
            destination = spaces.first { $0.index == destinationIndex }
        } else {
            destination = candidates.first(where: { $0.index > original.index }) ?? candidates.first
        }
        guard let destination, destination.spaceId != original.spaceId else {
            print("Choose an existing destination different from the source desktop"); return false
        }
        let initialFrame = window.frame
        if fullHeight {
            guard let visibleFrame = window.screen?.visibleFrame,
                  abs(initialFrame.height - visibleFrame.height) <= 1,
                  abs(initialFrame.minY - visibleFrame.minY) <= 1 else {
                print("Fixture does not fill its source screen's visible height")
                return false
            }
        }
        let outward = await move(window: window, to: destination)
        let outwardReleased = releaseSyntheticMouseButton()
        let returned = await move(window: window, to: original)
        let frame = window.frame
        let sameDisplay = original.displayId == destination.displayId
        let requireOriginalPosition = sameDisplay || fullHeight
        let geometry = abs(frame.width - initialFrame.width) <= 1 && abs(frame.height - initialFrame.height) <= 1
            && (!requireOriginalPosition || (abs(frame.minX - initialFrame.minX) <= 1 && abs(frame.minY - initialFrame.minY) <= 1))
        if !geometry { print("Fixture geometry changed unexpectedly") }
        let returnReleased = releaseSyntheticMouseButton()
        return outward && returned && geometry && outwardReleased && returnReleased
    }

    /// A killed worker cannot run its mouse-up defer. Correct only synthetic
    /// state; never release a physical button the user is currently holding.
    private static func releaseSyntheticMouseButton() -> Bool {
        guard CGEventSource.buttonState(.combinedSessionState, button: .left) else { return true }
        print("Mouse button remained down after the move")
        if !CGEventSource.buttonState(.hidSystemState, button: .left), let point = CGEvent(source: nil)?.location {
            CGEvent(mouseEventSource: nil, mouseType: .leftMouseUp, mouseCursorPosition: point,
                    mouseButton: .left)?.post(tap: .cgSessionEventTap)
        }
        return false
    }

    private static func move(window: NSWindow, to target: SpaceInfo) async -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: CommandLine.arguments[0])
        process.arguments = ["--worker", String(ProcessInfo.processInfo.processIdentifier), String(target.spaceId)]
        do { try process.run() } catch { print("Cannot start move worker: \(error)"); return false }
        for _ in 0..<600 {
            if !process.isRunning { break }
            try? await Task.sleep(for: .milliseconds(100))
        }
        if process.isRunning {
            process.terminate()
            try? await Task.sleep(for: .seconds(1))
            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
            print("Move worker timed out")
            return false
        }
        try? await Task.sleep(for: .milliseconds(300))
        let arrived = SpaceReader.spaceIds(containingWindow: CGWindowID(window.windowNumber)) == [target.spaceId]
            && SpaceReader.currentSpaceId(forDisplay: target.displayId) == target.spaceId
        let passed = process.terminationStatus == 0 && arrived
        print("\(passed ? "PASS" : "FAIL"): desktop \(target.index), membership \(arrived ? "verified" : "incorrect")")
        return passed
    }

    private static func restore(initialSpaces: [String: Int]) async -> Bool {
        var restored = true
        let spaces = SpaceReader.allSpaces(includeFullscreen: true)
        for (displayID, spaceID) in initialSpaces {
            if SpaceReader.currentSpaceId(forDisplay: displayID) == spaceID { continue }
            guard let space = spaces.first(where: { $0.spaceId == spaceID && $0.displayId == displayID }) else {
                print("An original desktop no longer exists; cannot restore it")
                restored = false
                continue
            }
            if !(await SpaceSwitcher.switchTo(space)) { restored = false }
        }
        try? await Task.sleep(for: .milliseconds(600))
        return restored
    }

    private static func fail(_ message: String) -> Never {
        print(message)
        exit(1)
    }
}
