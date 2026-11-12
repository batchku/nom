import Foundation
import CoreGraphics

enum WindowDragProbe {
    /// The first drag event may only start tracking, leaving half the requested
    /// displacement. An edge resize also shifts the origin, so size must
    /// stay unchanged before treating the gesture as a held window.
    static func isWindowDrag(before: CGRect, after: CGRect, expectedOffset: CGVector) -> Bool {
        guard expectedOffset.dx.isFinite, expectedOffset.dy.isFinite,
              (expectedOffset.dx == 0) != (expectedOffset.dy == 0)
        else { return false }

        let horizontal = expectedOffset.dx != 0
        let distance = horizontal ? expectedOffset.dx : expectedOffset.dy
        let deltaX = after.origin.x - before.origin.x
        let deltaY = after.origin.y - before.origin.y
        let progress = (horizontal ? deltaX : deltaY) * (distance > 0 ? 1 : -1)
        let perpendicular = horizontal ? deltaY : deltaX
        return abs(after.size.width - before.size.width) <= 1
            && abs(after.size.height - before.size.height) <= 1
            && abs(perpendicular) <= 1
            && progress >= abs(distance) / 2
            && progress <= abs(distance) + 1
    }

    /// Full-height windows can reject vertical movement. Probe horizontally
    /// toward whichever side of the display has more room.
    static func offset(for windowFrame: CGRect, within displayBounds: CGRect?) -> CGVector {
        guard let displayBounds else { return CGVector(dx: 10, dy: 0) }
        let leftAvailable = windowFrame.minX - displayBounds.minX
        let rightAvailable = displayBounds.maxX - windowFrame.maxX
        return CGVector(dx: leftAvailable > rightAvailable ? -10 : 10, dy: 0)
    }
}
