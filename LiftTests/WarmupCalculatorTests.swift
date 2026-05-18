import Testing
@testable import Lift

@Suite("WarmupCalculator")
struct WarmupCalculatorTests {
    @Test("100kg working weight produces the standard warmup ramp")
    func standardWarmupRamp() {
        let calculator = WarmupCalculator(weightLoading: WeightLoading(barWeightKg: 20, inventory: standardInventory()))

        #expect(calculator.warmupSets(forWorkingWeightKg: 100).elementsEqual(
            [(20.0, 5), (40.0, 5), (60.0, 3), (80.0, 2)],
            by: { ($0.weightKg, $0.reps) == ($1.0, $1.1) }
        ))
    }

    @Test("light working weights only do a bar warmup")
    func lightWorkingWeight() {
        let calculator = WarmupCalculator(weightLoading: WeightLoading(barWeightKg: 20, inventory: standardInventory()))

        #expect(calculator.warmupSets(forWorkingWeightKg: 25).elementsEqual(
            [(20.0, 5)],
            by: { ($0.weightKg, $0.reps) == ($1.0, $1.1) }
        ))
        #expect(calculator.warmupSets(forWorkingWeightKg: 22.5).elementsEqual(
            [(20.0, 5)],
            by: { ($0.weightKg, $0.reps) == ($1.0, $1.1) }
        ))
    }

    @Test("working weights at the light threshold only do a bar warmup")
    func lightThresholdOnlyUsesBarWarmup() {
        let calculator = WarmupCalculator(weightLoading: WeightLoading(barWeightKg: 20, inventory: standardInventory()))

        #expect(calculator.warmupSets(forWorkingWeightKg: 30).elementsEqual(
            [(20.0, 5)],
            by: { ($0.weightKg, $0.reps) == ($1.0, $1.1) }
        ))
    }

    @Test("working weight of 40kg uses easy-to-load warmups under the default policy")
    func roundedIntermediateWarmups() {
        let calculator = WarmupCalculator(weightLoading: WeightLoading(barWeightKg: 20, inventory: standardInventory()))

        #expect(calculator.warmupSets(forWorkingWeightKg: 40).elementsEqual(
            [(20.0, 5), (30.0, 2)],
            by: { ($0.weightKg, $0.reps) == ($1.0, $1.1) }
        ))
    }

    @Test("90kg squat snaps warmups to 5kg-friendly plates")
    func ninetyKgSquatUsesEasyPlates() {
        let calculator = WarmupCalculator(weightLoading: WeightLoading(barWeightKg: 20, inventory: standardInventory()))

        #expect(calculator.warmupSets(forWorkingWeightKg: 90).elementsEqual(
            [(20.0, 5), (40.0, 5), (50.0, 3), (70.0, 2)],
            by: { ($0.weightKg, $0.reps) == ($1.0, $1.1) }
        ))
    }

    @Test("deadlift policy skips the empty bar opener")
    func deadliftPolicySkipsBar() {
        let calculator = WarmupCalculator(weightLoading: WeightLoading(barWeightKg: 20, inventory: standardInventory()))

        #expect(calculator.warmupSets(forWorkingWeightKg: 100, policy: .deadlift).elementsEqual(
            [(40.0, 5), (60.0, 3), (80.0, 2)],
            by: { ($0.weightKg, $0.reps) == ($1.0, $1.1) }
        ))
    }

    @Test("heavy deadlift ramps to easy-loadable warmups")
    func heavyDeadliftRamp() {
        let calculator = WarmupCalculator(weightLoading: WeightLoading(barWeightKg: 20, inventory: standardInventory()))

        #expect(calculator.warmupSets(forWorkingWeightKg: 180, policy: .deadlift).elementsEqual(
            [(70.0, 5), (110.0, 3), (140.0, 2)],
            by: { ($0.weightKg, $0.reps) == ($1.0, $1.1) }
        ))
    }

    @Test("light deadlift skips bar entirely instead of warming with the bar")
    func lightDeadliftReturnsEmpty() {
        let calculator = WarmupCalculator(weightLoading: WeightLoading(barWeightKg: 20, inventory: standardInventory()))

        #expect(calculator.warmupSets(forWorkingWeightKg: 30, policy: .deadlift).isEmpty)
        #expect(calculator.warmupSets(forWorkingWeightKg: 25, policy: .deadlift).isEmpty)
    }

    @Test("max warmup ratio falls back to a lower loadable when the snap rounds over")
    func maxRatioGuardFallsBackLower() {
        let calculator = WarmupCalculator(weightLoading: WeightLoading(barWeightKg: 20, inventory: standardInventory()))

        // Deadlift 70kg: 0.80×70=56 → snaps to 60, but 60 > 70·0.85=59.5, falls back to next lower (50).
        #expect(calculator.warmupSets(forWorkingWeightKg: 70, policy: .deadlift).elementsEqual(
            [(30.0, 5), (40.0, 3), (50.0, 2)],
            by: { ($0.weightKg, $0.reps) == ($1.0, $1.1) }
        ))
    }

    @Test("default policy still returns a bar warmup at the light threshold")
    func defaultPolicyLightThresholdReturnsBar() {
        let calculator = WarmupCalculator(weightLoading: WeightLoading(barWeightKg: 20, inventory: standardInventory()))

        #expect(calculator.warmupSets(forWorkingWeightKg: 25, policy: .default).elementsEqual(
            [(20.0, 5)],
            by: { ($0.weightKg, $0.reps) == ($1.0, $1.1) }
        ))
    }

    @Test("row at the floor weight returns no warmups")
    func rowAtFloorReturnsNoWarmups() {
        let calculator = WarmupCalculator(weightLoading: WeightLoading(barWeightKg: 20, inventory: standardInventory()))

        #expect(calculator.warmupSets(forWorkingWeightKg: 30, policy: .row).isEmpty)
        #expect(calculator.warmupSets(forWorkingWeightKg: 25, policy: .row).isEmpty)
    }

    @Test("row just above the floor only does a single warmup at the floor")
    func rowJustAboveFloorReturnsFloorWarmup() {
        let calculator = WarmupCalculator(weightLoading: WeightLoading(barWeightKg: 20, inventory: standardInventory()))

        #expect(calculator.warmupSets(forWorkingWeightKg: 35, policy: .row).elementsEqual(
            [(30.0, 5)],
            by: { ($0.weightKg, $0.reps) == ($1.0, $1.1) }
        ))
        #expect(calculator.warmupSets(forWorkingWeightKg: 40, policy: .row).elementsEqual(
            [(30.0, 5)],
            by: { ($0.weightKg, $0.reps) == ($1.0, $1.1) }
        ))
    }

    @Test("row at a moderate weight starts from the floor and skips below-floor warmups")
    func rowAtModerateWeight() {
        let calculator = WarmupCalculator(weightLoading: WeightLoading(barWeightKg: 20, inventory: standardInventory()))

        #expect(calculator.warmupSets(forWorkingWeightKg: 50, policy: .row).elementsEqual(
            [(30.0, 5), (40.0, 2)],
            by: { ($0.weightKg, $0.reps) == ($1.0, $1.1) }
        ))
    }

    @Test("heavier rows produce multiple warmups all at or above the floor")
    func heavyRowRamp() {
        let calculator = WarmupCalculator(weightLoading: WeightLoading(barWeightKg: 20, inventory: standardInventory()))

        let result = calculator.warmupSets(forWorkingWeightKg: 60, policy: .row)
        #expect(result.elementsEqual(
            [(30.0, 5), (40.0, 3), (50.0, 2)],
            by: { ($0.weightKg, $0.reps) == ($1.0, $1.1) }
        ))
        for set in result {
            #expect(set.weightKg >= 30.0)
        }
    }

    @Test("row warmup policy is wired to the row exercise key")
    func rowExerciseUsesRowPolicy() {
        let exercise = Exercise(key: "row", name: "Row")
        #expect(exercise.warmupPolicy == .row)
    }

    private func standardInventory() -> [PlateInventoryItem] {
        [25, 20, 15, 10, 5, 2.5, 1.25].map { PlateInventoryItem(weightKg: $0, countTotal: 2) }
    }
}
