import Foundation

// From the end-to-end builds (first build on a new cache): extract 1 s, verify 0.4 s, setup
// about 9 s when the packages are not installed yet, dependencies 18 s (glslang is compiled),
// prepare 1 s, community 9 s, translate 9-14 s, compile 100-210 s, package 3-7 s.
private let allSteps: [(id: String, weight: Double)] = [
    ("extract", 1), ("verify", 1), ("setup", 1), ("dependencies", 10), ("prepare", 1),
    ("community", 5), ("translate", 7), ("compile", 75), ("package", 4),
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
