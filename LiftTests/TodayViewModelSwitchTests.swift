import Foundation
import SwiftData
import Testing
@testable import Lift

@Suite("TodayViewModel workout switching")
@MainActor
struct TodayViewModelSwitchTests {
    @Test("requestSwitch when nothing is logged silently swaps the workout")
    func requestSwitchSilentlyAppliesWhenUnlocked() async throws {
        let fixture = try makeFixture()
        let workoutA = try #require(fixture.viewModel.availableProgramDays.first(where: { $0.name == "Workout A" }))
        let workoutB = try #require(fixture.viewModel.availableProgramDays.first(where: { $0.name == "Workout B" }))

        fixture.viewModel.select(day: workoutA)
        #expect(fixture.viewModel.selectedProgramDay?.name == "Workout A")

        let outcome = fixture.viewModel.requestSwitch(to: workoutB)
        #expect(outcome == .applied)
        #expect(fixture.viewModel.selectedProgramDay?.name == "Workout B")
        #expect(fixture.viewModel.isProgramDayLocked == false)
    }

    @Test("requestSwitch returns noChange for the already-selected day")
    func requestSwitchReturnsNoChange() throws {
        let fixture = try makeFixture()
        let current = try #require(fixture.viewModel.selectedProgramDay)

        let outcome = fixture.viewModel.requestSwitch(to: current)

        #expect(outcome == .noChange)
    }

    @Test("requestSwitch silently discards an empty draft and switches")
    func requestSwitchSilentlyDiscardsEmptyDraft() async throws {
        let fixture = try makeFixture()
        let workoutA = try #require(fixture.viewModel.availableProgramDays.first(where: { $0.name == "Workout A" }))
        let workoutB = try #require(fixture.viewModel.availableProgramDays.first(where: { $0.name == "Workout B" }))

        fixture.viewModel.select(day: workoutA)
        let firstSet = try #require(fixture.viewModel.draftPlan?.exerciseLogs.first?.sets.first)
        try await fixture.viewModel.tapSet(firstSet.id)
        try fixture.viewModel.restoreSet(firstSet.id, actualReps: nil)

        try #require(fixture.viewModel.draftPlan?.exerciseLogs.first?.sets.first?.actualReps == nil)
        #expect(fixture.viewModel.isProgramDayLocked)

        let outcome = fixture.viewModel.requestSwitch(to: workoutB)

        #expect(outcome == .applied)
        #expect(fixture.viewModel.selectedProgramDay?.name == "Workout B")
        #expect(fixture.viewModel.isProgramDayLocked == false)

        let drafts = try DraftSessionService(modelContext: fixture.context).allDrafts()
        #expect(drafts.isEmpty)
    }

    @Test("requestSwitch with logged sets requires confirmation and does not swap")
    func requestSwitchRequiresConfirmation() async throws {
        let fixture = try makeFixture()
        let workoutA = try #require(fixture.viewModel.availableProgramDays.first(where: { $0.name == "Workout A" }))
        let workoutB = try #require(fixture.viewModel.availableProgramDays.first(where: { $0.name == "Workout B" }))

        fixture.viewModel.select(day: workoutA)
        let firstSet = try #require(fixture.viewModel.draftPlan?.exerciseLogs.first?.sets.first)
        try await fixture.viewModel.tapSet(firstSet.id)

        let outcome = fixture.viewModel.requestSwitch(to: workoutB)

        guard case let .requiresConfirmation(loggedSetCount) = outcome else {
            Issue.record("Expected .requiresConfirmation, got \(outcome)")
            return
        }
        #expect(loggedSetCount == 1)
        #expect(fixture.viewModel.selectedProgramDay?.name == "Workout A")
        #expect(fixture.viewModel.isProgramDayLocked)
    }

    @Test("confirmDiscardAndSwitch deletes the draft and switches to the new day")
    func confirmDiscardAndSwitchDiscardsDraft() async throws {
        let fixture = try makeFixture()
        let workoutA = try #require(fixture.viewModel.availableProgramDays.first(where: { $0.name == "Workout A" }))
        let workoutB = try #require(fixture.viewModel.availableProgramDays.first(where: { $0.name == "Workout B" }))

        fixture.viewModel.select(day: workoutA)
        let firstSet = try #require(fixture.viewModel.draftPlan?.exerciseLogs.first?.sets.first)
        try await fixture.viewModel.tapSet(firstSet.id)
        try #require(fixture.viewModel.isProgramDayLocked)

        try fixture.viewModel.confirmDiscardAndSwitch(to: workoutB)

        #expect(fixture.viewModel.selectedProgramDay?.name == "Workout B")
        #expect(fixture.viewModel.isProgramDayLocked == false)
        #expect(fixture.viewModel.activeDraftStartedAt == nil)

        let drafts = try DraftSessionService(modelContext: fixture.context).allDrafts()
        #expect(drafts.isEmpty)
    }

    private func makeFixture() throws -> SwitchFixture {
        let container = try makeInMemoryContainer()
        let context = ModelContext(container)
        try LiftSeeder().seedIfNeeded(in: context)

        let viewModel = TodayViewModel(
            modelContext: context,
            clock: { fixtureDate() },
            timeZone: .utc,
            restTimer: RecordingRestTimerForSwitchTests()
        )
        viewModel.load()
        return SwitchFixture(context: context, viewModel: viewModel)
    }

    private func fixtureDate() -> Date {
        Date(timeIntervalSince1970: 1_735_689_600)
    }
}

private struct SwitchFixture {
    let context: ModelContext
    let viewModel: TodayViewModel
}

@MainActor
private final class RecordingRestTimerForSwitchTests: RestTimerStarting {
    func start(exerciseLogID _: UUID, exerciseName _: String, setID _: UUID, durationSeconds _: Int, now _: Date) async {}
    func skip() async {}
}

private extension TimeZone {
    static let utc = TimeZone(secondsFromGMT: 0)!
}
