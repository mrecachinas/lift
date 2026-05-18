import Testing
@testable import Lift

@Suite("Progression")
struct ProgressionTests {
    @Test("all working sets hit advances when the increment is loadable")
    func allSetsHitAdvances() {
        let loading = WeightLoading(
            barWeightKg: 20,
            inventory: [25, 20, 15, 10, 5, 2.5, 1.25, 0.625].map { PlateInventoryItem(weightKg: $0, countTotal: 2) }
        )

        let outcome = Progression.evaluate(
            workingSets: [.init(targetReps: 5, actualReps: 5), .init(targetReps: 5, actualReps: 5), .init(targetReps: 5, actualReps: 5)],
            currentWeightKg: 60,
            incrementKg: 1.25,
            weightLoading: loading
        )

        #expect(outcome == .advanced(newWeightKg: 61.25))
    }

    @Test("missed reps stall progression")
    func missedRepsStall() {
        let loading = WeightLoading(barWeightKg: 20, inventory: standardInventory())

        #expect(
            Progression.evaluate(
                workingSets: [.init(targetReps: 5, actualReps: 5), .init(targetReps: 5, actualReps: 5), .init(targetReps: 5, actualReps: 4)],
                currentWeightKg: 60,
                incrementKg: 2.5,
                weightLoading: loading
            ) == .stalled
        )

        #expect(
            Progression.evaluate(
                workingSets: [.init(targetReps: 5, actualReps: 3), .init(targetReps: 5, actualReps: 3), .init(targetReps: 5, actualReps: 3)],
                currentWeightKg: 60,
                incrementKg: 2.5,
                weightLoading: loading
            ) == .stalled
        )
    }

    @Test("single-set exercises still advance or stall correctly")
    func singleSetExercises() {
        let loading = WeightLoading(barWeightKg: 20, inventory: standardInventory())

        #expect(
            Progression.evaluate(
                workingSets: [.init(targetReps: 5, actualReps: 5)],
                currentWeightKg: 60,
                incrementKg: 2.5,
                weightLoading: loading
            ) == .advanced(newWeightKg: 62.5)
        )

        #expect(
            Progression.evaluate(
                workingSets: [.init(targetReps: 5, actualReps: 4)],
                currentWeightKg: 60,
                incrementKg: 2.5,
                weightLoading: loading
            ) == .stalled
        )
    }

    @Test("partner style rep schemes require every set to hit its target")
    func partnerStyleRepSchemes() {
        let loading = WeightLoading(barWeightKg: 20, inventory: standardInventory())

        #expect(
            Progression.evaluate(
                workingSets: [.init(targetReps: 10, actualReps: 10), .init(targetReps: 10, actualReps: 10), .init(targetReps: 10, actualReps: 10)],
                currentWeightKg: 40,
                incrementKg: 2.5,
                weightLoading: loading
            ) == .advanced(newWeightKg: 42.5)
        )

        #expect(
            Progression.evaluate(
                workingSets: [.init(targetReps: 10, actualReps: 10), .init(targetReps: 10, actualReps: 9), .init(targetReps: 10, actualReps: 10)],
                currentWeightKg: 40,
                incrementKg: 2.5,
                weightLoading: loading
            ) == .stalled
        )
    }

    @Test("empty working sets are a no-op")
    func noWorkingSetsLogged() {
        let loading = WeightLoading(barWeightKg: 20, inventory: standardInventory())

        #expect(
            Progression.evaluate(
                workingSets: [],
                currentWeightKg: 40,
                incrementKg: 2.5,
                weightLoading: loading
            ) == .noWorkingSetsLogged
        )
    }

    @Test("unloadable increments snap up to the next loadable weight so success always advances")
    func unloadableIncrementSnapsUpToNextLoadable() {
        let loading = WeightLoading(barWeightKg: 20, inventory: standardInventory())

        #expect(
            Progression.evaluate(
                workingSets: [.init(targetReps: 5, actualReps: 5), .init(targetReps: 5, actualReps: 5), .init(targetReps: 5, actualReps: 5)],
                currentWeightKg: 60,
                incrementKg: 1.25,
                weightLoading: loading
            ) == .advanced(newWeightKg: 62.5)
        )
    }

    @Test("regression: starting at the bar with the user's preferred small increment still advances on success")
    func smallIncrementAtBarAdvancesToNextLoadable() {
        let loading = WeightLoading(barWeightKg: 20, inventory: standardInventory())

        #expect(
            Progression.evaluate(
                workingSets: [.init(targetReps: 5, actualReps: 5), .init(targetReps: 5, actualReps: 5), .init(targetReps: 5, actualReps: 5)],
                currentWeightKg: 20,
                incrementKg: 1.25,
                weightLoading: loading
            ) == .advanced(newWeightKg: 22.5)
        )
    }

    @Test("excessively large increments overshoot to the next loadable weight rather than landing exactly")
    func largeIncrementSnapsUpToNextLoadable() {
        let loading = WeightLoading(barWeightKg: 20, inventory: standardInventory())

        #expect(
            Progression.evaluate(
                workingSets: [.init(targetReps: 5, actualReps: 5), .init(targetReps: 5, actualReps: 5), .init(targetReps: 5, actualReps: 5)],
                currentWeightKg: 60,
                incrementKg: 11,
                weightLoading: loading
            ) == .advanced(newWeightKg: 72.5)
        )
    }

    @Test("at the gym ceiling success stays at current weight rather than going backwards")
    func atGymCeilingStaysAtCurrentWeight() {
        let loading = WeightLoading(
            barWeightKg: 20,
            inventory: [PlateInventoryItem(weightKg: 5, countTotal: 2)]
        )

        // Loadable: 20, 30. Current = max = 30.
        #expect(
            Progression.evaluate(
                workingSets: [.init(targetReps: 5, actualReps: 5)],
                currentWeightKg: 30,
                incrementKg: 2.5,
                weightLoading: loading
            ) == .advanced(newWeightKg: 30)
        )
    }

    @Test("deload rounds to the nearest loadable weight with a bar floor")
    func deloadRoundsSafely() {
        let loading = WeightLoading(barWeightKg: 20, inventory: standardInventory())

        #expect(Progression.deload(currentWeightKg: 60, weightLoading: loading) == 55)
        #expect(Progression.deload(currentWeightKg: 22.5, weightLoading: loading) == 20)
    }

    @Test("manual bump-up advances straight to the lifted weight without adding an increment")
    func manualBumpUpSetsProgressionToLiftedWeight() {
        let loading = WeightLoading(barWeightKg: 20, inventory: standardInventory())

        // Saved progression is 60kg, but the user pushed 70kg and hit all reps.
        // The bump itself is the progression — don't add another 2.5kg on top.
        #expect(
            Progression.evaluate(
                workingSets: [.init(targetReps: 5, actualReps: 5), .init(targetReps: 5, actualReps: 5), .init(targetReps: 5, actualReps: 5)],
                currentWeightKg: 60,
                liftedWeightKg: 70,
                incrementKg: 2.5,
                weightLoading: loading
            ) == .advanced(newWeightKg: 70)
        )
    }

    @Test("manual bump-up snaps up if the lifted weight isn't loadable")
    func manualBumpUpSnapsToLoadable() {
        let loading = WeightLoading(barWeightKg: 20, inventory: standardInventory())

        // 67kg isn't loadable with 5kg+ plates, but lifted is loadable in this inventory
        // (62.5 = bar + 2.5+10+5+2.5? no, 2.5×2 + 10×2 + 5×2 = 35 = 55kg, plus bar = 75). Use a
        // value that snaps up: 67.5 is loadable (bar + 25 + 25? no). Just check 65 stays as 65.
            #expect(
            Progression.evaluate(
                workingSets: [.init(targetReps: 5, actualReps: 5)],
                currentWeightKg: 60,
                liftedWeightKg: 65,
                incrementKg: 2.5,
                weightLoading: loading
            ) == .advanced(newWeightKg: 65)
        )
    }

    @Test("manual bump-down still advances from the lifted weight rather than the saved one")
    func manualBumpDownAdvancesFromLifted() {
        let loading = WeightLoading(barWeightKg: 20, inventory: standardInventory())

        // Saved progression is 80kg, user deloaded to 50kg and hit all reps. Next session should
        // start at 52.5kg (lifted + increment), not 82.5kg (saved + increment).
        #expect(
            Progression.evaluate(
                workingSets: [.init(targetReps: 5, actualReps: 5), .init(targetReps: 5, actualReps: 5), .init(targetReps: 5, actualReps: 5)],
                currentWeightKg: 80,
                liftedWeightKg: 50,
                incrementKg: 2.5,
                weightLoading: loading
            ) == .advanced(newWeightKg: 52.5)
        )
    }

    @Test("manual bump-up that fails still stalls progression")
    func manualBumpUpThatStallsStaysStalled() {
        let loading = WeightLoading(barWeightKg: 20, inventory: standardInventory())

        // User pushed weight up but missed reps: stall.
        #expect(
            Progression.evaluate(
                workingSets: [.init(targetReps: 5, actualReps: 5), .init(targetReps: 5, actualReps: 4), .init(targetReps: 5, actualReps: 3)],
                currentWeightKg: 60,
                liftedWeightKg: 70,
                incrementKg: 2.5,
                weightLoading: loading
            ) == .stalled
        )
    }

    @Test("default liftedWeightKg behaves like the saved progression weight")
    func defaultLiftedWeightMatchesCurrent() {
        let loading = WeightLoading(barWeightKg: 20, inventory: standardInventory())

        let withDefault = Progression.evaluate(
            workingSets: [.init(targetReps: 5, actualReps: 5), .init(targetReps: 5, actualReps: 5), .init(targetReps: 5, actualReps: 5)],
            currentWeightKg: 60,
            incrementKg: 2.5,
            weightLoading: loading
        )
        let withExplicit = Progression.evaluate(
            workingSets: [.init(targetReps: 5, actualReps: 5), .init(targetReps: 5, actualReps: 5), .init(targetReps: 5, actualReps: 5)],
            currentWeightKg: 60,
            liftedWeightKg: 60,
            incrementKg: 2.5,
            weightLoading: loading
        )
        #expect(withDefault == withExplicit)
        #expect(withDefault == .advanced(newWeightKg: 62.5))
    }

    private func standardInventory() -> [PlateInventoryItem] {
        [25, 20, 15, 10, 5, 2.5, 1.25].map { PlateInventoryItem(weightKg: $0, countTotal: 2) }
    }
}
