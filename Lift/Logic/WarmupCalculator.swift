import Foundation

struct WarmupPolicy: Sendable, Equatable {
    var includesBarWarmup: Bool
    var minimumWarmupPlateKg: Double
    var maxWarmupRatio: Double
    var minimumWarmupWeightKg: Double

    static let `default` = WarmupPolicy(
        includesBarWarmup: true,
        minimumWarmupPlateKg: 5.0,
        maxWarmupRatio: 0.85,
        minimumWarmupWeightKg: 0
    )

    static let deadlift = WarmupPolicy(
        includesBarWarmup: false,
        minimumWarmupPlateKg: 5.0,
        maxWarmupRatio: 0.85,
        minimumWarmupWeightKg: 0
    )

    static let row = WarmupPolicy(
        includesBarWarmup: false,
        minimumWarmupPlateKg: 5.0,
        maxWarmupRatio: 0.85,
        minimumWarmupWeightKg: 30.0
    )
}

struct WarmupCalculator: Sendable {
    let weightLoading: WeightLoading

    func warmupSets(
        forWorkingWeightKg working: Double,
        policy: WarmupPolicy = .default
    ) -> [(weightKg: Double, reps: Int)] {
        let bar = weightLoading.barWeightKg
        let warmupLoading = weightLoading.filtered(minimumPlateKg: policy.minimumWarmupPlateKg)

        // The "starting" warmup weight: the floor if one is configured (e.g. row at 30kg), else
        // the bar. This is also the floor for every other warmup in the ramp.
        let baseWarmup: Double = {
            guard policy.minimumWarmupWeightKg > 0 else { return bar }
            var snapped = warmupLoading.nearestLoadable(policy.minimumWarmupWeightKg)
            if snapped < policy.minimumWarmupWeightKg,
               let higher = warmupLoading.nextHigherLoadable(snapped) {
                snapped = higher
            }
            return snapped
        }()

        let includesStartingWarmup = policy.includesBarWarmup || policy.minimumWarmupWeightKg > 0

        // Working weight is at or below where we'd warm up: nothing useful to do.
        if working <= baseWarmup {
            return []
        }

        // Light working weight: a single starting warmup (bar for default, floor for row).
        // Deadlift falls through to empty.
        if working <= baseWarmup + 10 {
            return includesStartingWarmup ? [(baseWarmup, 5)] : []
        }

        let maxAllowed = working * policy.maxWarmupRatio
        var sets: [(weightKg: Double, reps: Int)] = []

        if includesStartingWarmup {
            sets.append((baseWarmup, 5))
        }

        let scheme: [(multiplier: Double, reps: Int)] = [
            (0.40, 5),
            (0.60, 3),
            (0.80, 2)
        ]

        for step in scheme {
            var snapped = warmupLoading.nearestLoadable(working * step.multiplier)
            if snapped > maxAllowed {
                guard let lower = warmupLoading.nextLowerLoadable(snapped),
                      lower > baseWarmup,
                      lower <= maxAllowed
                else { continue }
                snapped = lower
            }
            guard snapped > baseWarmup, snapped < working else { continue }
            guard sets.last?.weightKg != snapped else { continue }
            sets.append((snapped, step.reps))
        }

        return sets
    }
}

extension Exercise {
    var warmupPolicy: WarmupPolicy {
        switch key {
        case "deadlift": return .deadlift
        case "row": return .row
        default: return .default
        }
    }
}
