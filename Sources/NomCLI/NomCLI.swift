import Foundation
import NomCore

@main
struct NomCLI {
    static func main() {
        let args = Array(CommandLine.arguments.dropFirst())
        guard let command = args.first else {
            printUsage()
            return
        }

        nameStore.migrateLegacyConfigIfNeeded(
            liveSpaces: SpaceReader.allSpaces(includeFullscreen: true)
        )

        switch command {
        case "current": handleCurrent()
        case "list": handleList()
        case "set": handleSet(Array(args.dropFirst()))
        case "unset": handleUnset(Array(args.dropFirst()))
        case "goto": handleGoto(Array(args.dropFirst()))
        default: printUsage()
        }
    }

    // MARK: - Commands

    private static func handleCurrent() {
        if let state = readState(),
           let current = state.spaces.first(where: { $0.id == state.currentSpaceId }) {
            print(current.displayName)
        } else {
            // Fallback: read directly from SkyLight
            let spaces = SpaceReader.allSpaces()
            let activeId = SpaceReader.activeSpaceId()
            if let active = spaces.first(where: { $0.spaceId == activeId }) {
                let name = nameStore.allNames()[active.persistentKey]
                print(name ?? active.displayName)
            } else {
                print("Unknown")
            }
        }
    }

    private static func handleList() {
        let names = nameStore.allNames()
        let spaces = SpaceReader.allSpaces()
        let activeId = SpaceReader.activeSpaceId()

        for space in spaces {
            let name = names[space.persistentKey] ?? space.displayName
            let marker = space.spaceId == activeId ? " *" : ""
            print("\(space.index): \(name) [\(space.displayId)]\(marker)")
        }
    }

    private static func handleSet(_ args: [String]) {
        guard args.count >= 2, let index = Int(args[0]) else {
            print("Usage: nom set <index> <name>")
            return
        }
        let name = args.dropFirst().joined(separator: " ")
        let spaces = SpaceReader.allSpaces()
        guard let space = spaces.first(where: { $0.index == index }) else {
            print("No space at index \(index)")
            return
        }

        nameStore.setName(name, for: space.persistentKey)
        notifyApp()

        print("Named space \(index) -> \"\(name)\"")
    }

    private static func handleUnset(_ args: [String]) {
        guard let indexStr = args.first, let index = Int(indexStr) else {
            print("Usage: nom unset <index>")
            return
        }
        let spaces = SpaceReader.allSpaces()
        guard let space = spaces.first(where: { $0.index == index }) else {
            print("No space at index \(index)")
            return
        }

        nameStore.setName(nil, for: space.persistentKey)
        notifyApp()

        print("Removed name from space \(index)")
    }

    private static func handleGoto(_ args: [String]) {
        guard let indexStr = args.first, let index = Int(indexStr) else {
            print("Usage: nom goto <index>")
            return
        }
        let spaces = SpaceReader.allSpaces()
        guard let space = spaces.first(where: { $0.index == index }) else {
            print("No space at index \(index)")
            return
        }
        guard SpaceSwitcher.hasAccessibilityPermission else {
            print("Needs Accessibility permission for your terminal (System Settings > Privacy & Security > Accessibility)")
            exit(1)
        }
        if SpaceSwitcher.jump(toIndex: index) {
            // Keep the process alive long enough to restore the hotkey state
            Thread.sleep(forTimeInterval: 0.6)
            let name = nameStore.allNames()[space.persistentKey]
            print("Jumped to \(index): \(name ?? space.displayName)")
        } else {
            print("Could not jump to space \(index)")
            exit(1)
        }
    }

    // MARK: - Direct file I/O (no actor needed for CLI)

    private static let nameStore = NameStore()

    private static func readState() -> NomState? {
        guard let data = try? Data(contentsOf: ConfigStore.statePath) else { return nil }
        return try? JSONDecoder().decode(NomState.self, from: data)
    }

    private static func notifyApp() {
        DistributedNotificationCenter.default().postNotificationName(
            .init("com.teambrilliant.nom.configChanged"),
            object: nil
        )
    }

    private static func printUsage() {
        print("""
        nom -- name your macOS Spaces

        Usage:
          nom current        Show current space name
          nom list           List all spaces with names
          nom set N "name"   Name space N (global MC index)
          nom unset N        Remove name from space N
          nom goto N         Jump to space N (needs Accessibility)
        """)
    }
}
