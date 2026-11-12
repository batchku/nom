import Testing
@testable import NomCore

struct SpaceMoveRouteTests {
    @Test func movesRightInDisplayOrder() throws {
        let route = try #require(SpaceMoveRoute(
            spaceIds: [80, 3, 41, 12], source: 80, destination: 12
        ))

        #expect(route.hotKey == 81)
        #expect(route.maxTransitions == 3)
        #expect(route.allowsProgress(from: 80, to: 3))
        #expect(route.allowsProgress(from: 3, to: 41))
        #expect(route.allowsProgress(from: 41, to: 12))
    }

    @Test func movesLeftInDisplayOrder() throws {
        let route = try #require(SpaceMoveRoute(
            spaceIds: [80, 3, 41, 12], source: 12, destination: 80
        ))

        #expect(route.hotKey == 79)
        #expect(route.maxTransitions == 3)
        #expect(route.allowsProgress(from: 12, to: 41))
        #expect(route.allowsProgress(from: 41, to: 3))
        #expect(route.allowsProgress(from: 3, to: 80))
    }

    @Test func allowsNativeTransitionsToSkipIntermediateSpaces() throws {
        let right = try #require(SpaceMoveRoute(
            spaceIds: [5, 66, 100, 22, 8], source: 66, destination: 8
        ))
        let left = try #require(SpaceMoveRoute(
            spaceIds: [5, 66, 100, 22, 8], source: 8, destination: 66
        ))

        #expect(right.allowsProgress(from: 66, to: 22))
        #expect(right.allowsProgress(from: 66, to: 8))
        #expect(left.allowsProgress(from: 8, to: 100))
        #expect(left.allowsProgress(from: 8, to: 66))
    }

    @Test func rejectsStallsReversalsAndOvershootToTheRight() throws {
        let route = try #require(SpaceMoveRoute(
            spaceIds: [10, 20, 30, 40, 50], source: 20, destination: 40
        ))

        #expect(!route.allowsProgress(from: 30, to: 30))
        #expect(!route.allowsProgress(from: 30, to: 20))
        #expect(!route.allowsProgress(from: 30, to: 50))
        #expect(!route.allowsProgress(from: 40, to: 50))
        #expect(!route.allowsProgress(from: 10, to: 30))
    }

    @Test func rejectsStallsReversalsAndOvershootToTheLeft() throws {
        let route = try #require(SpaceMoveRoute(
            spaceIds: [10, 20, 30, 40, 50], source: 40, destination: 20
        ))

        #expect(!route.allowsProgress(from: 30, to: 30))
        #expect(!route.allowsProgress(from: 30, to: 40))
        #expect(!route.allowsProgress(from: 30, to: 10))
        #expect(!route.allowsProgress(from: 20, to: 10))
        #expect(!route.allowsProgress(from: 50, to: 30))
    }

    @Test func supportsMoreThanSixteenSpaces() throws {
        let route = try #require(SpaceMoveRoute(
            spaceIds: Array(1...25), source: 2, destination: 25
        ))

        #expect(route.hotKey == 81)
        #expect(route.maxTransitions == 23)
        #expect(route.allowsProgress(from: 16, to: 17))
        #expect(route.allowsProgress(from: 24, to: 25))
    }

    @Test func rejectsMissingEndpointsAndAmbiguousLayout() {
        #expect(SpaceMoveRoute(spaceIds: [], source: 1, destination: 2) == nil)
        #expect(SpaceMoveRoute(spaceIds: [1, 2], source: 3, destination: 2) == nil)
        #expect(SpaceMoveRoute(spaceIds: [1, 2], source: 1, destination: 3) == nil)
        #expect(SpaceMoveRoute(spaceIds: [1, 2, 1], source: 1, destination: 2) == nil)
    }

    @Test func rejectsProgressOutsideTheDisplayLayout() throws {
        let route = try #require(SpaceMoveRoute(
            spaceIds: [10, 20, 30], source: 10, destination: 30
        ))

        #expect(!route.allowsProgress(from: 99, to: 20))
        #expect(!route.allowsProgress(from: 20, to: 99))
    }

    @Test func alreadyAtDestinationNeedsNoTransitions() throws {
        let route = try #require(SpaceMoveRoute(
            spaceIds: [10, 20, 30], source: 20, destination: 20
        ))

        #expect(route.maxTransitions == 0)
        #expect(!route.allowsProgress(from: 20, to: 20))
        #expect(!route.allowsProgress(from: 20, to: 10))
        #expect(!route.allowsProgress(from: 20, to: 30))
    }
}
