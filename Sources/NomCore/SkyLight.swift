import Foundation

// MARK: - SkyLight Private API Declarations

@_silgen_name("SLSMainConnectionID")
package func SLSMainConnectionID() -> Int32

@_silgen_name("SLSGetActiveSpace")
package func SLSGetActiveSpace(_ cid: Int32) -> Int

@_silgen_name("SLSCopyManagedDisplaySpaces")
package func SLSCopyManagedDisplaySpaces(_ cid: Int32) -> CFArray

@_silgen_name("SLSSpaceGetType")
package func SLSSpaceGetType(_ cid: Int32, _ space: Int) -> Int32

@_silgen_name("SLSManagedDisplayIsAnimating")
package func SLSManagedDisplayIsAnimating(_ cid: Int32, _ display: CFString) -> Bool

// MARK: - Symbolic Hotkeys (safe: settings toggle + real keyboard event path)
//
// Used to jump to a space the same way Hammerspoon's hs.spaces.gotoSpace does:
// temporarily enable the "Switch to Desktop N" hotkey (ID 118 + N-1), post the
// matching keyboard event, restore the previous enabled state. The switch runs
// through Mission Control's normal path — unlike SLSManagedDisplaySetCurrentSpace,
// which corrupts the compositor (see CLAUDE.md).

@_silgen_name("SLSGetSymbolicHotKeyValue")
package func SLSGetSymbolicHotKeyValue(
    _ hotKey: Int32,
    _ keyEquivalent: UnsafeMutablePointer<UInt16>?,
    _ virtualKeyCode: UnsafeMutablePointer<UInt16>?,
    _ modifiers: UnsafeMutablePointer<UInt64>?
) -> Int32

@_silgen_name("SLSIsSymbolicHotKeyEnabled")
package func SLSIsSymbolicHotKeyEnabled(_ hotKey: Int32) -> Bool

@_silgen_name("SLSSetSymbolicHotKeyEnabled")
package func SLSSetSymbolicHotKeyEnabled(_ hotKey: Int32, _ enabled: Bool) -> Int32
