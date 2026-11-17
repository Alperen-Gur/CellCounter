import Foundation

/// Decides when the hidden Workbench gives back its decoded image resources.
/// The Workbench view stays mounted, so an explicit active flag drives this
/// rather than `onDisappear`.
nonisolated struct WorkbenchViewResidency: Equatable, Sendable {
    enum Action: Equatable, Sendable { case none, release, restore }

    private(set) var isActive: Bool
    /// True while the displayed image has been dropped (or was never loaded)
    /// and must be reloaded on return.
    private(set) var released: Bool

    init(startsActive: Bool = true) {
        isActive = startsActive
        released = !startsActive
    }

    mutating func transition(toActive active: Bool, hasUnsavedDraft: Bool,
                             hasDisplayedImage: Bool) -> Action {
        guard active != isActive else { return .none }
        isActive = active
        if active {
            guard released else { return .none }
            released = false
            return .restore
        }
        // An unsaved draft, selection or running operation owns the displayed
        // image; never discard it.
        guard !hasUnsavedDraft, hasDisplayedImage else { return .none }
        released = true
        return .release
    }
}

/// Poll cadence for the shared project activity refresh. Each process start is
/// costly (the service has no persistent request path), so the interval grows
/// while nothing changes and returns to the base as soon as something does.
nonisolated struct WorkbenchPollBackoff: Equatable, Sendable {
    static let baseInterval = 5.0
    static let ceilingInterval = 30.0
    static let idlePollsPerStep = 3

    private(set) var idleStreak = 0

    var interval: Double {
        let step = min(idleStreak / Self.idlePollsPerStep, 3)
        return min(Self.ceilingInterval, Self.baseInterval * Double(1 << step))
    }

    mutating func record(changed: Bool) { idleStreak = changed ? 0 : idleStreak + 1 }
    mutating func reset() { idleStreak = 0 }
}
