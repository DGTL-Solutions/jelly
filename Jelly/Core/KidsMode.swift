import Foundation

extension AppModel {
    /// The age rating the active profile is limited to, or `nil` when it is a normal profile.
    var kidsRating: String? { KidsPIN.rating(for: session) }

    var isKids: Bool { kidsRating != nil }

    func enableKids(rating: String, pin: String, ratings: [ParentalRating]) {
        guard let session else { return }
        KidsPIN.saveTable(ratings)
        if !KidsPIN.isSet { KidsPIN.set(pin) }
        KidsPIN.setRating(rating, for: session)
        kidsChanged()
    }

    /// Leaves the kids mode of the active profile; the caller has asked for the PIN.
    func disableKids() {
        guard let session else { return }
        KidsPIN.setRating(nil, for: session)
        kidsChanged()
    }

    /// Runs `action` right away on a normal profile; on a kids profile only after the PIN was entered.
    func requireParent(_ action: @escaping () -> Void) {
        guard isKids, Date() > parentUnlockedUntil else { action(); return }
        parentAction = action
    }

    func parentApproved() {
        let action = parentAction
        parentAction = nil
        action?()
    }

    func parentCancelled() { parentAction = nil }

    private func kidsChanged() {
        objectWillChange.send()
        contentChanged()
    }
}
