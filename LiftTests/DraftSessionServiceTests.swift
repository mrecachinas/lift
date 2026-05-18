import Foundation
import SwiftData
import Testing
@testable import Lift

@Suite("DraftSessionService")
@MainActor
struct DraftSessionServiceTests {
    @Test("createDraft materializes a persisted draft session from workout A")
    func createDraftMaterializesPersistedSession() throws {
        let container = try makeInMemoryContainer()
        let context = ModelContext(container)
        try LiftSeeder().seedIfNeeded(in: context)

        let workoutA = try requireDay(named: "Workout A", from: context)
        setWeight(60, forExerciseKey: "squat", in: workoutA)
        setWeight(42.5, forExerciseKey: "bench", in: workoutA)
        setWeight(45, forExerciseKey: "row", in: workoutA)

        let service = try makeService(context: context)
        let session = try service.createDraft(
            for: workoutA,
            now: fixtureDate(),
            calendar: calendar(timeZone: try #require(TimeZone(identifier: "America/Los_Angeles")))
        )

        #expect(session.status == .draft)
        #expect(session.workoutDayID == "2024-12-31")
        #expect(session.exerciseLogs.count == 3)
        let logsByName = Dictionary(uniqueKeysWithValues: session.exerciseLogs.map { ($0.exerciseNameSnapshot, $0) })
        #expect(Set(logsByName.keys) == ["Squat", "Bench", "Row"])
        #expect(logsByName["Squat"]?.targetWeightKgSnapshot == 60)
        #expect(logsByName["Bench"]?.targetWeightKgSnapshot == 42.5)
        #expect(logsByName["Row"]?.targetWeightKgSnapshot == 45)
        #expect(logsByName.values.allSatisfy { $0.targetSetsSnapshot == 3 })
        #expect(logsByName.values.allSatisfy { $0.targetRepsSnapshot == 5 })

        let squatSets = try #require(session.exerciseLogs.first(where: { $0.exerciseNameSnapshot == "Squat" })?.sets)
        #expect(squatSets.filter { $0.kind == .warmup }.count == 3)
        #expect(squatSets.filter { $0.kind == .working }.count == 3)

        let benchSets = try #require(session.exerciseLogs.first(where: { $0.exerciseNameSnapshot == "Bench" })?.sets)
        #expect(benchSets.filter { $0.kind == .warmup }.count == 2)
        #expect(benchSets.filter { $0.kind == .working }.count == 3)

        let rowSets = try #require(session.exerciseLogs.first(where: { $0.exerciseNameSnapshot == "Row" })?.sets)
        #expect(rowSets.filter { $0.kind == .warmup }.count == 1)
        #expect(rowSets.filter { $0.kind == .working }.count == 3)

        let allSets = session.exerciseLogs.flatMap(\.sets)
        #expect(allSets.allSatisfy { $0.actualReps == nil })
        #expect(allSets.allSatisfy { $0.id != .zero })
        #expect(Set(allSets.map(\.id)).count == allSets.count)
    }

    @Test("draft snapshots stay unchanged after progression mutations")
    func draftSnapshotsStayIndependent() throws {
        let container = try makeInMemoryContainer()
        let context = ModelContext(container)
        try LiftSeeder().seedIfNeeded(in: context)

        let workoutA = try requireDay(named: "Workout A", from: context)
        let service = try makeService(context: context)
        let session = try service.createDraft(for: workoutA, now: fixtureDate(), calendar: calendar(timeZone: .utc))

        let squatProgression = try requireProgression(forExerciseKey: "squat", from: context)
        squatProgression.currentWeightKg = 85
        try context.save()

        let refetched = try requireSession(id: session.id, from: context)
        let squatLog = try #require(refetched.exerciseLogs.first(where: { $0.exerciseNameSnapshot == "Squat" }))
        #expect(squatLog.targetWeightKgSnapshot == 20)
    }

    @Test("logged set ids remain stable and unique across save and refetch")
    func loggedSetIDsRoundTrip() throws {
        let container = try makeInMemoryContainer()
        let context = ModelContext(container)
        try LiftSeeder().seedIfNeeded(in: context)

        let workoutA = try requireDay(named: "Workout A", from: context)
        let service = try makeService(context: context)
        let session = try service.createDraft(for: workoutA, now: fixtureDate(), calendar: calendar(timeZone: .utc))
        let expectedIDs = session.exerciseLogs.flatMap(\.sets).map(\.id)

        let refetched = try requireSession(id: session.id, from: context)
        let reloadedIDs = refetched.exerciseLogs.flatMap(\.sets).map(\.id)

        #expect(Set(reloadedIDs) == Set(expectedIDs))
        #expect(Set(reloadedIDs).count == reloadedIDs.count)
    }

    @Test("createDraft rejects a second draft for the same local day")
    func createDraftRejectsSecondDraftForSameDay() throws {
        let container = try makeInMemoryContainer()
        let context = ModelContext(container)
        try LiftSeeder().seedIfNeeded(in: context)

        let workoutA = try requireDay(named: "Workout A", from: context)
        let workoutB = try requireDay(named: "Workout B", from: context)
        let service = try makeService(context: context)
        let existing = try service.createDraft(for: workoutA, now: fixtureDate(), calendar: calendar(timeZone: .utc))

        do {
            _ = try service.createDraft(for: workoutB, now: fixtureDate(), calendar: calendar(timeZone: .utc))
            Issue.record("Expected duplicate draft creation to throw")
        } catch let error as DraftSessionError {
            #expect(error == .draftAlreadyExistsForToday(existingID: existing.id))
        }
    }

    @Test("currentDraft only returns today's draft sessions")
    func currentDraftOnlyReturnsTodayDrafts() throws {
        let container = try makeInMemoryContainer()
        let context = ModelContext(container)
        try LiftSeeder().seedIfNeeded(in: context)

        let service = try makeService(context: context)
        #expect(service.currentDraft(now: fixtureDate(), calendar: calendar(timeZone: .utc)) == nil)

        let workoutA = try requireDay(named: "Workout A", from: context)
        let completed = WorkoutSession(
            workoutDayID: LocalDay.id(for: fixtureDate(), in: .utc),
            timeZoneIdentifierAtStart: TimeZone.utc.identifier,
            startedAt: fixtureDate(),
            endedAt: fixtureDate().addingTimeInterval(60),
            programDay: workoutA,
            status: .completed
        )
        context.insert(completed)
        try context.save()

        #expect(service.currentDraft(now: fixtureDate(), calendar: calendar(timeZone: .utc)) == nil)

        let draft = try service.createDraft(for: workoutA, now: fixtureDate(), calendar: calendar(timeZone: .utc))
        #expect(service.currentDraft(now: fixtureDate(), calendar: calendar(timeZone: .utc))?.id == draft.id)
    }

    @Test("allDrafts returns drafts newest first")
    func allDraftsReturnsNewestFirst() throws {
        let container = try makeInMemoryContainer()
        let context = ModelContext(container)
        try LiftSeeder().seedIfNeeded(in: context)

        let workoutA = try requireDay(named: "Workout A", from: context)
        let service = try makeService(context: context)

        let older = try service.createDraft(
            for: workoutA,
            now: fixtureDate(),
            calendar: calendar(timeZone: .utc)
        )
        let newer = try service.createDraft(
            for: workoutA,
            now: fixtureDate().addingTimeInterval(86_400 * 2),
            calendar: calendar(timeZone: .utc)
        )

        #expect(service.allDrafts().map(\.id) == [newer.id, older.id])
    }

    @Test("discard removes the session and its child rows")
    func discardRemovesCascadeGraph() throws {
        let container = try makeInMemoryContainer()
        let context = ModelContext(container)
        try LiftSeeder().seedIfNeeded(in: context)

        let workoutA = try requireDay(named: "Workout A", from: context)
        let service = try makeService(context: context)
        let session = try service.createDraft(for: workoutA, now: fixtureDate(), calendar: calendar(timeZone: .utc))

        service.discard(session)

        #expect(try fetchAll(WorkoutSession.self, from: context).isEmpty)
        #expect(try fetchAll(ExerciseLog.self, from: context).isEmpty)
        #expect(try fetchAll(LoggedSet.self, from: context).isEmpty)
    }

    @Test("endWithoutProgression closes the draft without mutating progression state")
    func endWithoutProgressionUpdatesOnlySessionState() throws {
        let container = try makeInMemoryContainer()
        let context = ModelContext(container)
        try LiftSeeder().seedIfNeeded(in: context)

        let workoutA = try requireDay(named: "Workout A", from: context)
        let squatProgression = try requireProgression(forExerciseKey: "squat", from: context)
        let originalWeight = squatProgression.currentWeightKg

        let service = try makeService(context: context)
        let session = try service.createDraft(for: workoutA, now: fixtureDate(), calendar: calendar(timeZone: .utc))
        let endedAt = fixtureDate().addingTimeInterval(90)

        service.endWithoutProgression(session, now: endedAt)

        #expect(session.status == .endedNoProgression)
        #expect(session.endedAt == endedAt)
        #expect(squatProgression.currentWeightKg == originalWeight)
    }

    @Test("workoutDayID is stored from the creation calendar day")
    func workoutDayIDUsesCreationCalendarDay() throws {
        let container = try makeInMemoryContainer()
        let context = ModelContext(container)
        try LiftSeeder().seedIfNeeded(in: context)

        let workoutA = try requireDay(named: "Workout A", from: context)
        let losAngeles = try #require(TimeZone(identifier: "America/Los_Angeles"))
        let service = try makeService(context: context)

        let session = try service.createDraft(
            for: workoutA,
            now: fixtureDate(),
            calendar: calendar(timeZone: losAngeles)
        )

        #expect(session.workoutDayID == "2024-12-31")
        #expect(session.timeZoneIdentifierAtStart == losAngeles.identifier)
    }

    private func makeService(context: ModelContext) throws -> DraftSessionService {
        try DraftSessionService(modelContext: context)
    }

    private func requireDay(named name: String, from context: ModelContext) throws -> ProgramDay {
        let days = try fetchAll(ProgramDay.self, from: context)
        guard let day = days.first(where: { $0.name == name }) else {
            Issue.record("Missing program day \(name)")
            fatalError("Missing program day")
        }
        return day
    }

    private func requireProgression(forExerciseKey key: String, from context: ModelContext) throws -> ExerciseProgression {
        let progressions = try fetchAll(ExerciseProgression.self, from: context)
        guard let progression = progressions.first(where: { $0.exercise?.key == key }) else {
            Issue.record("Missing progression \(key)")
            fatalError("Missing progression")
        }
        return progression
    }

    private func requireSession(id: UUID, from context: ModelContext) throws -> WorkoutSession {
        let sessions = try fetchAll(WorkoutSession.self, from: context)
        guard let session = sessions.first(where: { $0.id == id }) else {
            Issue.record("Missing session \(id)")
            fatalError("Missing session")
        }
        return session
    }

    private func setWeight(_ weight: Double, forExerciseKey key: String, in day: ProgramDay) {
        day.orderedSlots
            .first(where: { $0.exerciseProgression?.exercise?.key == key })?
            .exerciseProgression?
            .currentWeightKg = weight
    }

    private func fixtureDate() -> Date {
        Date(timeIntervalSince1970: 1_735_689_600)
    }

    private func calendar(timeZone: TimeZone) -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        return calendar
    }
}

private extension TimeZone {
    static let utc = TimeZone(secondsFromGMT: 0)!
}

private extension UUID {
    static let zero = UUID(uuidString: "00000000-0000-0000-0000-000000000000")!
}
