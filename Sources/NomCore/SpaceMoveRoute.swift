/// Bounds a held-window move to one display's current Mission Control order.
/// Native arrow transitions may skip fullscreen spaces, so progress can span
/// multiple entries as long as it stays between the source and destination.
struct SpaceMoveRoute {
    let hotKey: Int32
    let maxTransitions: Int

    private let spaceIds: [Int]
    private let sourceIndex: Int
    private let destinationIndex: Int

    init?(spaceIds: [Int], source: Int, destination: Int) {
        guard Set(spaceIds).count == spaceIds.count,
              let sourceIndex = spaceIds.firstIndex(of: source),
              let destinationIndex = spaceIds.firstIndex(of: destination)
        else { return nil }

        self.spaceIds = spaceIds
        self.sourceIndex = sourceIndex
        self.destinationIndex = destinationIndex
        hotKey = destinationIndex < sourceIndex ? 79 : 81
        maxTransitions = abs(destinationIndex - sourceIndex)
    }

    func allowsProgress(from source: Int, to destination: Int) -> Bool {
        guard maxTransitions > 0,
              let fromIndex = spaceIds.firstIndex(of: source),
              let toIndex = spaceIds.firstIndex(of: destination)
        else { return false }

        if sourceIndex < destinationIndex {
            return fromIndex >= sourceIndex && fromIndex < destinationIndex
                && toIndex > fromIndex && toIndex <= destinationIndex
        }
        return fromIndex <= sourceIndex && fromIndex > destinationIndex
            && toIndex < fromIndex && toIndex >= destinationIndex
    }
}
