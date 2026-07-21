import Foundation

@MainActor
final class ActionDispatcher {
    private let spaceSwitcher: SpaceSwitcher

    init(spaceSwitcher: SpaceSwitcher) {
        self.spaceSwitcher = spaceSwitcher
    }

    @discardableResult
    func dispatch(
        _ action: BoundAction,
        source: SpaceInputSource
    ) -> Bool {
        spaceSwitcher.submit(action.spaceSwitchAction, source: source)
    }
}
