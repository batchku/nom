import Foundation
import CoreGraphics
import Testing
@testable import NomCore

struct WindowDragProbeTests {
    private let initial = CGRect(x: 100, y: 200, width: 600, height: 400)

    @Test(arguments: [5.0, 10.0])
    func acceptsEstablishedWindowDrag(drop: Double) {
        #expect(WindowDragProbe.isWindowDrag(
            before: initial, after: initial.offsetBy(dx: 0, dy: drop), expectedOffset: CGVector(dx: 0, dy: 10)
        ))
    }

    @Test func rejectsTopEdgeResize() {
        let resized = CGRect(x: 100, y: 210, width: 600, height: 390)

        #expect(!WindowDragProbe.isWindowDrag(
            before: initial, after: resized, expectedOffset: CGVector(dx: 0, dy: 10)
        ))
    }

    @Test func rejectsWidthChange() {
        let resized = CGRect(x: 100, y: 210, width: 590, height: 400)

        #expect(!WindowDragProbe.isWindowDrag(
            before: initial, after: resized, expectedOffset: CGVector(dx: 0, dy: 10)
        ))
    }

    @Test(arguments: [0.0, -10.0, 4.9, 11.1, 100.0])
    func rejectsMovementOutsideProbeRange(drop: Double) {
        #expect(!WindowDragProbe.isWindowDrag(
            before: initial, after: initial.offsetBy(dx: 0, dy: drop), expectedOffset: CGVector(dx: 0, dy: 10)
        ))
    }

    @Test(arguments: [-1.1, 1.1, 100.0])
    func rejectsHorizontalMovement(offset: Double) {
        #expect(!WindowDragProbe.isWindowDrag(
            before: initial, after: initial.offsetBy(dx: offset, dy: 10), expectedOffset: CGVector(dx: 0, dy: 10)
        ))
    }

    @Test func acceptsGeometryRoundingAtTolerance() {
        let rounded = CGRect(x: 101, y: 211, width: 601, height: 399)

        #expect(WindowDragProbe.isWindowDrag(
            before: initial, after: rounded, expectedOffset: CGVector(dx: 0, dy: 10)
        ))
    }

    @Test func scalesMinimumMovementWithRequestedProbe() {
        #expect(WindowDragProbe.isWindowDrag(
            before: initial, after: initial.offsetBy(dx: 0, dy: 10), expectedOffset: CGVector(dx: 0, dy: 20)
        ))
        #expect(!WindowDragProbe.isWindowDrag(
            before: initial, after: initial.offsetBy(dx: 0, dy: 9), expectedOffset: CGVector(dx: 0, dy: 20)
        ))
    }

    @Test(arguments: [0.0, Double.infinity, Double.nan])
    func rejectsInvalidRequestedProbe(drop: Double) {
        #expect(!WindowDragProbe.isWindowDrag(
            before: initial, after: initial.offsetBy(dx: 0, dy: 10), expectedOffset: CGVector(dx: 0, dy: drop)
        ))
    }

    @Test(arguments: [-10.0, 10.0], [false, true])
    func acceptsBothDirectionsOnEitherAxis(distance: Double, horizontal: Bool) {
        let expected = CGVector(dx: horizontal ? distance : 0, dy: horizontal ? 0 : distance)
        for fraction in [0.5, 1.0] {
            let after = initial.offsetBy(dx: expected.dx * fraction, dy: expected.dy * fraction)
            #expect(WindowDragProbe.isWindowDrag(before: initial, after: after, expectedOffset: expected))
        }
    }

    @Test(arguments: [-10.0, 10.0], [false, true])
    func rejectsReverseMovementOnEitherAxis(distance: Double, horizontal: Bool) {
        let expected = CGVector(dx: horizontal ? distance : 0, dy: horizontal ? 0 : distance)
        let after = initial.offsetBy(dx: -expected.dx, dy: -expected.dy)

        #expect(!WindowDragProbe.isWindowDrag(before: initial, after: after, expectedOffset: expected))
    }

    @Test(arguments: [-10.0, 10.0], [false, true])
    func rejectsOvershootOnEitherAxis(distance: Double, horizontal: Bool) {
        let expected = CGVector(dx: horizontal ? distance : 0, dy: horizontal ? 0 : distance)
        let after = initial.offsetBy(dx: expected.dx * 1.2, dy: expected.dy * 1.2)

        #expect(!WindowDragProbe.isWindowDrag(before: initial, after: after, expectedOffset: expected))
    }

    @Test(arguments: [-10.0, 10.0], [-1.1, 1.1])
    func rejectsVerticalDriftDuringHorizontalProbe(distance: Double, drift: Double) {
        let after = initial.offsetBy(dx: distance, dy: drift)

        #expect(!WindowDragProbe.isWindowDrag(
            before: initial, after: after, expectedOffset: CGVector(dx: distance, dy: 0)
        ))
    }

    @Test func rejectsLeftEdgeResize() {
        let resized = CGRect(x: 110, y: 200, width: 590, height: 400)

        #expect(!WindowDragProbe.isWindowDrag(
            before: initial, after: resized, expectedOffset: CGVector(dx: 10, dy: 0)
        ))
    }

    @Test(arguments: [
        CGVector(dx: 0, dy: 0), CGVector(dx: 10, dy: 10), CGVector(dx: -10, dy: 10),
        CGVector(dx: CGFloat.infinity, dy: 0), CGVector(dx: 0, dy: -CGFloat.infinity),
        CGVector(dx: CGFloat.nan, dy: 0), CGVector(dx: 0, dy: CGFloat.nan),
    ])
    func rejectsInvalidAxes(expected: CGVector) {
        #expect(!WindowDragProbe.isWindowDrag(
            before: initial, after: initial.offsetBy(dx: 10, dy: 0), expectedOffset: expected
        ))
    }

    @Test func fullHeightWindowUsesHorizontalRoom() {
        let display = CGRect(x: 0, y: 0, width: 1920, height: 1080)
        let window = CGRect(x: 100, y: 0, width: 600, height: 1080)
        let offset = WindowDragProbe.offset(for: window, within: display)

        #expect(offset.dx == 10)
        #expect(offset.dy == 0)
    }

    @Test func rightEdgeWindowProbesLeft() {
        let display = CGRect(x: 0, y: 0, width: 1920, height: 1080)
        let window = CGRect(x: 1320, y: 0, width: 600, height: 1080)
        let offset = WindowDragProbe.offset(for: window, within: display)

        #expect(offset.dx == -10)
        #expect(offset.dy == 0)
    }

    @Test func leftEdgeWindowProbesRight() {
        let display = CGRect(x: 0, y: 0, width: 1920, height: 1080)
        let window = CGRect(x: 0, y: 200, width: 600, height: 400)

        #expect(WindowDragProbe.offset(for: window, within: display).dx == 10)
    }

    @Test func equalRoomAndMissingDisplayProbeRight() {
        let display = CGRect(x: 0, y: 0, width: 1920, height: 1080)
        let centered = CGRect(x: 660, y: 200, width: 600, height: 400)

        #expect(WindowDragProbe.offset(for: centered, within: display).dx == 10)
        #expect(WindowDragProbe.offset(for: display, within: display).dx == 10)
        #expect(WindowDragProbe.offset(for: centered, within: nil).dx == 10)
        #expect(WindowDragProbe.offset(for: centered, within: nil).dy == 0)
    }

    @Test func displayCoordinatesMayHaveNegativeOrigins() {
        let display = CGRect(x: -1920, y: -1080, width: 1920, height: 1080)
        let window = CGRect(x: -600, y: -1080, width: 600, height: 1080)

        #expect(WindowDragProbe.offset(for: window, within: display).dx == -10)
    }
}
