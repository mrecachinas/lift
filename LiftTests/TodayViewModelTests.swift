import Foundation
import SwiftData
import Testing
@testable import Lift

@Suite("TodayViewModel")
@MainActor
struct TodayViewModelTests {
    @Test("load defaults to workout A and builds a draft plan")
    func loadDefaultsToWorkoutAAndBuildsDraftPlan() throws {
        let container = try makeInMemoryContainer()
        let context = ModelContext(container)
        try LiftSeeder().seedIfNeeded(in: context)

        let viewModel = TodayViewModel(
            modelContext: context,
            clock: { fixtureDate() },
            timeZone: .utc
        )

        viewModel.load()

        #expect(viewModel.selectedProgramDay?.name == "Workout A")
        let draftPlan = try #require(viewModel.draftPlan)
        #expect(draftPlan.exerciseLogs.count == 3)
        let selectedDay = try #require(viewModel.selectedProgramDay)
        #expect(draftPlan.exerciseLogs.count == selectedDay.orderedSlots.count)
    }

    @Test("completed workout A advances selection to workout B")
    func completedWorkoutAAdvancesToWorkoutB() throws {
        let container = try makeInMemoryContainer()
        let context = ModelContext(container)
        try LiftSeeder().seedIfNeeded(in: context)

        let workoutA = try requireDay(named: "Workout A", from: context)
        let completedSession = WorkoutSession(
            workoutDayID: "2025-01-01",
            timeZoneIdentifierAtStart: TimeZone.utc.identifier,
            startedAt: fixtureDate(),
            programDay: workoutA,
            status: .completed
        )
        context.insert(completedSession)
        try context.save()

        let viewModel = TodayViewModel(
            modelContext: context,
            clock: { fixtureDate() },
            timeZone: .utc
        )

        viewModel.refresh()

        #expect(viewModel.selectedProgramDay?.name == "Workout B")
        let draftPlan = try #require(viewModel.draftPlan)
        let selectedDay = try #require(viewModel.selectedProgramDay)
        #expect(draftPlan.exerciseLogs.count == selectedDay.orderedSlots.count)
    }

    @Test("load prefers today's persisted draft and locks workout selection")
    func loadPrefersPersistedDraftAndLocksSelection() throws {
        let container = try makeInMemoryContainer()
        let context = ModelContext(container)
        try LiftSeeder().seedIfNeeded(in: context)

        let workoutB = try requireDay(named: "Workout B", from: context)
        let service = try DraftSessionService(modelContext: context)
        let session = try service.createDraft(for: workoutB, now: fixtureDate(), calendar: utcCalendar())
        session.exerciseLogs[0].sets.first(where: { $0.kind == .working })?.actualReps = 5
        try context.save()

        let viewModel = TodayViewModel(
            modelContext: context,
            clock: { fixtureDate() },
            timeZone: .utc
        )

        viewModel.load()

        #expect(viewModel.selectedProgramDay?.name == "Workout B")
        #expect(viewModel.isProgramDayLocked)
        #expect(viewModel.programDayLockHint == "Workout B — in progress. Tap to switch.")
        let draftPlan = try #require(viewModel.draftPlan)
        #expect(draftPlan.exerciseLogs.map(\.exerciseNameSnapshot) == ["Squat", "OHP", "Deadlift"])
        let completedSet = draftPlan.exerciseLogs
            .flatMap(\.sets)
            .first(where: { $0.kind == .working && $0.actualReps == 5 })
        #expect(completedSet != nil)
    }

    @Test("prepareDraftIfNeeded creates a persisted draft for the selected day")
    func prepareDraftIfNeededCreatesPersistedDraft() throws {
        let container = try makeInMemoryContainer()
        let context = ModelContext(container)
        try LiftSeeder().seedIfNeeded(in: context)

        let viewModel = TodayViewModel(
            modelContext: context,
            clock: { fixtureDate() },
            timeZone: .utc
        )
        viewModel.load()

        let created = try viewModel.prepareDraftIfNeeded()
        let service = try DraftSessionService(modelContext: context)

        #expect(created?.status == .draft)
        #expect(service.currentDraft(now: fixtureDate(), calendar: utcCalendar())?.id == created?.id)
    }

    @Test("finish workout stays disabled until a working set is logged")
    func finishWorkoutRequiresAtLeastOneLoggedWorkingSet() throws {
        let container = try makeInMemoryContainer()
        let context = ModelContext(container)
        try LiftSeeder().seedIfNeeded(in: context)

        let viewModel = TodayViewModel(
            modelContext: context,
            clock: { fixtureDate() },
            timeZone: .utc
        )
        viewModel.load()

        #expect(viewModel.canOpenFinishSheet == false)
        #expect(viewModel.finishWorkoutHint == "Log at least one working set to finish")

        let workoutA = try requireDay(named: "Workout A", from: context)
        let service = try DraftSessionService(modelContext: context)
        let session = try service.createDraft(for: workoutA, now: fixtureDate(), calendar: utcCalendar())
        session.exerciseLogs.first?.sets.first(where: { $0.kind == .working })?.actualReps = 5
        try context.save()

        viewModel.refresh()

        #expect(viewModel.canOpenFinishSheet)
        #expect(viewModel.finishWorkoutHint == nil)
        #expect(viewModel.finishWorkoutPreview?.pendingWorkingSetCount == 8)
        #expect(viewModel.finishWorkoutPreview?.canApplyProgression == false)
    }

    @Test("finalizeCurrentSession advances today to the next workout and unlocks the picker")
    func finalizeCurrentSessionAdvancesToNextWorkout() throws {
        let container = try makeInMemoryContainer()
        let context = ModelContext(container)
        try LiftSeeder().seedIfNeeded(in: context)

        let workoutA = try requireDay(named: "Workout A", from: context)
        let service = try DraftSessionService(modelContext: context)
        let session = try service.createDraft(for: workoutA, now: fixtureDate(), calendar: utcCalendar())
        for exerciseLog in session.exerciseLogs {
            for set in exerciseLog.sets where set.kind == .working {
                set.actualReps = set.targetReps
            }
        }
        try context.save()

        let viewModel = TodayViewModel(
            modelContext: context,
            clock: { fixtureDate() },
            timeZone: .utc
        )
        viewModel.load()

        let result = try viewModel.finalizeCurrentSession()

        #expect(result.nextProgramDayName == "Workout B")
        #expect(viewModel.selectedProgramDay?.name == "Workout B")
        #expect(viewModel.isProgramDayLocked == false)
        #expect(viewModel.finishWorkoutPreview == nil)
    }

    @Test("endCurrentSessionWithoutProgression keeps the same workout selected and unlocks the picker")
    func endCurrentSessionWithoutProgressionKeepsSameWorkout() throws {
        let container = try makeInMemoryContainer()
        let context = ModelContext(container)
        try LiftSeeder().seedIfNeeded(in: context)

        let workoutA = try requireDay(named: "Workout A", from: context)
        let service = try DraftSessionService(modelContext: context)
        let session = try service.createDraft(for: workoutA, now: fixtureDate(), calendar: utcCalendar())
        session.exerciseLogs.first?.sets.first(where: { $0.kind == .working })?.actualReps = 5
        try context.save()

        let viewModel = TodayViewModel(
            modelContext: context,
            clock: { fixtureDate() },
            timeZone: .utc
        )
        viewModel.load()

        try viewModel.endCurrentSessionWithoutProgression()

        #expect(viewModel.selectedProgramDay?.name == "Workout A")
        #expect(viewModel.isProgramDayLocked == false)
        #expect(viewModel.finishWorkoutPreview == nil)
    }

    @Test("finalizeCurrentSession saves the workout window to HealthKit")
    func finalizeSavesWorkoutToHealthKit() async throws {
        let container = try makeInMemoryContainer()
        let context = ModelContext(container)
        try LiftSeeder().seedIfNeeded(in: context)

        let workoutA = try requireDay(named: "Workout A", from: context)
        let service = try DraftSessionService(modelContext: context)
        let startedAt = fixtureDate()
        let session = try service.createDraft(for: workoutA, now: startedAt, calendar: utcCalendar())
        for exerciseLog in session.exerciseLogs {
            for set in exerciseLog.sets where set.kind == .working {
                set.actualReps = set.targetReps
            }
        }
        try context.save()

        let endedAt = startedAt.addingTimeInterval(45 * 60)
        let healthKit = HealthKitStub(status: .sharingAuthorized)
        let viewModel = TodayViewModel(
            modelContext: context,
            clock: { endedAt },
            timeZone: .utc,
            healthKit: healthKit
        )
        viewModel.load()

        _ = try viewModel.finalizeCurrentSession()
        await viewModel.pendingHealthSaveTask?.value

        #expect(healthKit.savedWorkouts == [HealthKitStub.SavedWorkout(start: startedAt, end: endedAt)])
    }

    @Test("endCurrentSessionWithoutProgression also saves to HealthKit")
    func endWithoutProgressionSavesToHealthKit() async throws {
        let container = try makeInMemoryContainer()
        let context = ModelContext(container)
        try LiftSeeder().seedIfNeeded(in: context)

        let workoutA = try requireDay(named: "Workout A", from: context)
        let service = try DraftSessionService(modelContext: context)
        let startedAt = fixtureDate()
        let session = try service.createDraft(for: workoutA, now: startedAt, calendar: utcCalendar())
        session.exerciseLogs.first?.sets.first(where: { $0.kind == .working })?.actualReps = 5
        try context.save()

        let endedAt = startedAt.addingTimeInterval(20 * 60)
        let healthKit = HealthKitStub(status: .sharingAuthorized)
        let viewModel = TodayViewModel(
            modelContext: context,
            clock: { endedAt },
            timeZone: .utc,
            healthKit: healthKit
        )
        viewModel.load()

        try viewModel.endCurrentSessionWithoutProgression()
        await viewModel.pendingHealthSaveTask?.value

        #expect(healthKit.savedWorkouts == [HealthKitStub.SavedWorkout(start: startedAt, end: endedAt)])
    }

    @Test("first finalize prompts for HealthKit auth before saving")
    func firstFinalizePromptsForAuth() async throws {
        let container = try makeInMemoryContainer()
        let context = ModelContext(container)
        try LiftSeeder().seedIfNeeded(in: context)

        let workoutA = try requireDay(named: "Workout A", from: context)
        let service = try DraftSessionService(modelContext: context)
        let startedAt = fixtureDate()
        let session = try service.createDraft(for: workoutA, now: startedAt, calendar: utcCalendar())
        for exerciseLog in session.exerciseLogs {
            for set in exerciseLog.sets where set.kind == .working {
                set.actualReps = set.targetReps
            }
        }
        try context.save()

        let healthKit = HealthKitStub(status: .notDetermined)
        let viewModel = TodayViewModel(
            modelContext: context,
            clock: { startedAt.addingTimeInterval(60) },
            timeZone: .utc,
            healthKit: healthKit
        )
        viewModel.load()

        _ = try viewModel.finalizeCurrentSession()
        await viewModel.pendingHealthSaveTask?.value

        #expect(healthKit.authorizationRequested)
        #expect(healthKit.savedWorkouts.count == 1)
    }

    @Test("finalize skips the HealthKit save when access is denied")
    func finalizeSkipsHealthKitWhenDenied() async throws {
        let container = try makeInMemoryContainer()
        let context = ModelContext(container)
        try LiftSeeder().seedIfNeeded(in: context)

        let workoutA = try requireDay(named: "Workout A", from: context)
        let service = try DraftSessionService(modelContext: context)
        let session = try service.createDraft(for: workoutA, now: fixtureDate(), calendar: utcCalendar())
        for exerciseLog in session.exerciseLogs {
            for set in exerciseLog.sets where set.kind == .working {
                set.actualReps = set.targetReps
            }
        }
        try context.save()

        let healthKit = HealthKitStub(status: .denied)
        let viewModel = TodayViewModel(
            modelContext: context,
            clock: { fixtureDate() },
            timeZone: .utc,
            healthKit: healthKit
        )
        viewModel.load()

        _ = try viewModel.finalizeCurrentSession()
        await viewModel.pendingHealthSaveTask?.value

        #expect(healthKit.savedWorkouts.isEmpty)
    }

    private func requireDay(named name: String, from context: ModelContext) throws -> ProgramDay {
        let days = try fetchAll(ProgramDay.self, from: context)
        guard let day = days.first(where: { $0.name == name }) else {
            Issue.record("Missing program day \(name)")
            fatalError("Missing program day")
        }
        return day
    }

    private func fixtureDate() -> Date {
        Date(timeIntervalSince1970: 1_735_689_600)
    }

    private func utcCalendar() -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .utc
        return calendar
    }
}

private extension TimeZone {
    static let utc = TimeZone(secondsFromGMT: 0)!
}
