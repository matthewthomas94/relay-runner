import Foundation

/// A complete touch sequence must be a short, stationary four-finger tap.
/// Individual positions reject pinches even when their centroid stays still.
struct FourFingerTapGesture {
    struct Contact: Equatable {
        let id: Int32
        let position: CGPoint
    }

    private var beganAt: TimeInterval?
    private var origins: [Int32: CGPoint] = [:]
    private var reachedFour = false
    private var rejected = false
    private var lifting = false
    private var previousCount = 0

    mutating func update(
        contacts: [Contact],
        at time: TimeInterval,
        buttonDown: Bool = false
    ) -> Bool {
        guard !contacts.isEmpty else {
            let fires = reachedFour && !rejected && !buttonDown
                && beganAt.map { (0.04...0.35).contains(time - $0) } == true
            self = Self()
            return fires
        }
        if beganAt == nil { beganAt = time }
        if buttonDown || contacts.count > 4 || time - (beganAt ?? time) > 0.35 {
            rejected = true
        }
        if contacts.count < previousCount { lifting = true }
        if lifting && contacts.count > previousCount { rejected = true }
        previousCount = contacts.count
        for contact in contacts {
            let point = contact.position
            guard point.x.isFinite, point.y.isFinite,
                  (0...1).contains(point.x), (0...1).contains(point.y) else {
                rejected = true
                continue
            }
            if let origin = origins[contact.id] {
                if hypot(point.x - origin.x, point.y - origin.y) > 0.03 { rejected = true }
            } else {
                origins[contact.id] = point
            }
        }
        if origins.count > 4 { rejected = true }
        if contacts.count == 4 { reachedFour = true }
        return false
    }

    mutating func cancel() { rejected = true }
}
