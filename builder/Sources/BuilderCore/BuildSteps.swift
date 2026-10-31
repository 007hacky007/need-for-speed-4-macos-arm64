import Foundation

private let allSteps: [(id: String, weight: Double)] = [
    ("extract", 4), ("verify", 4), ("setup", 2), ("dependencies", 6), ("prepare", 4),
    ("community", 10), ("translate", 35), ("compile", 40), ("package", 5),
]

/// The pipeline steps in order with their share of the work; `community` only with the option.
public func buildSteps(community: Bool) -> [(id: String, weight: Double)] {
    allSteps.filter { community || $0.id != "community" }
}

/// Fraction (0...1) of the work done when the given step begins. An unknown step id gives 1,
/// so callers ignore step ids that are not in `buildSteps`.
public func progressFraction(atStart stepID: String, community: Bool) -> Double {
    let steps = buildSteps(community: community)
    let total = steps.reduce(0) { $0 + $1.weight }
    var sum = 0.0
    for step in steps {
        if step.id == stepID { return sum / total }
        sum += step.weight
    }
    return 1
}
