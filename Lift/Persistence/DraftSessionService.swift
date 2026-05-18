import Foundation
import SwiftData

enum DraftSessionError: Error, Equatable {
    case draftAlreadyExistsForToday(existingID: UUID)
    case missingUserConfiguration
    case cannotFinalizeWithPendingSets(count: Int)

    static func == (lhs: DraftSessionError, rhs: DraftSessionError) -> Bool {
        switch (lhs, rhs) {
        case let (.draftAlreadyExistsForToday(left), .draftAlreadyExistsForToday(right)):
            return left == right
        case (.missingUserConfiguration, .missingUserConfiguration):
            return true
        case let (.cannotFinalizeWithPendingSets(left), .cannotFinalizeWithPendingSets(right)):
            return left == right
        default:
            return false
        }
    }
}

struct FinalizeResult: Sendable, Equatable {
    struct PerExercise: Sendable, Equatable {
        let exerciseName: String
        let oldWeightKg: Double
        let newWeightKg: Double
        let didProgress: Bool
        let stalledCount: Int
    }

    let perExercise: [PerExercise]
    let nextProgramDayName: String?
}

struct FinishWorkoutPreview: Sendable, Equatable {
    enum State: Sendable, Equatable {
        case incomplete
        case willProgress
        case stalled
        case unchanged
    }

    struct PerExercise: Sendable, Equatable {
        let exerciseName: String
        let setSummary: String
        let oldWeightKg: Double
        let newWeightKg: Double
        let stalledCount: Int
        let state: State
    }

    let perExercise: [PerExercise]
    let pendingWorkingSetCount: Int
    let canApplyProgression: Bool
    let hasAnyLoggedWorkingSet: Bool
    let nextProgramDayName: String?
    let nextProgramExerciseNames: [String]
}

@MainActor
struct DraftSessionService {
    let modelContext: ModelContext
    let factory: DraftSessionFactory
    let weightLoading: WeightLoading

    init(
        modelContext: ModelContext,
        factory: DraftSessionFactory = DraftSessionFactory()
    ) throws {
        self.modelContext = modelContext
        self.factory = factory
        self.weightLoading = try Self.makeWeightLoading(from: modelContext)
    }

    func currentDraft(now: Date = .now, calendar: Calendar = .current) -> WorkoutSession? {
        let todayID = LocalDay.id(for: now, in: calendar.timeZone)
        return allDrafts().first(where: { $0.workoutDayID == todayID })
    }

    func allDrafts() -> [WorkoutSession] {
        let descriptor = FetchDescriptor<WorkoutSession>(
            sortBy: [SortDescriptor(\WorkoutSession.startedAt, order: .reverse)]
        )

        do {
            return try modelContext.fetch(descriptor).filter { $0.status == .draft }
        } catch {
            assertionFailure("Failed to fetch draft sessions: \(error)")
            return []
        }
    }

    func createDraft(
        for programDay: ProgramDay,
        now: Date = .now,
        calendar: Calendar = .current
    ) throws -> WorkoutSession {
        if let existing = currentDraft(now: now, calendar: calendar) {
            throw DraftSessionError.draftAlreadyExistsForToday(existingID: existing.id)
        }

        let warmupCalculator = WarmupCalculator(weightLoading: weightLoading)
        let draftPlan = factory.makeDraft(
            programDay: programDay,
            startedAt: now,
            timeZone: calendar.timeZone,
            warmupCalculator: warmupCalculator
        )

        let session = WorkoutSession(
            id: draftPlan.id,
            workoutDayID: draftPlan.workoutDayID,
            timeZoneIdentifierAtStart: calendar.timeZone.identifier,
            startedAt: draftPlan.startedAt,
            programDay: programDay,
            exerciseLogs: [],
            status: .draft
        )

        modelContext.insert(session)

        for draftLog in draftPlan.exerciseLogs {
            guard let exercise = draftLog.exercise else { continue }

            let exerciseLog = ExerciseLog(
                id: draftLog.id,
                session: session,
                exercise: exercise,
                exerciseNameSnapshot: draftLog.exerciseNameSnapshot,
                targetWeightKgSnapshot: draftLog.targetWeightKgSnapshot,
                targetSetsSnapshot: draftLog.targetSetsSnapshot,
                targetRepsSnapshot: draftLog.targetRepsSnapshot,
                sets: []
            )

            modelContext.insert(exerciseLog)
            session.exerciseLogs.append(exerciseLog)

            for draftSet in draftLog.sets {
                let loggedSet = LoggedSet(
                    id: draftSet.id,
                    log: exerciseLog,
                    kind: draftSet.kind,
                    index: draftSet.index,
                    weightKg: draftSet.weightKg,
                    targetReps: draftSet.targetReps,
                    actualReps: nil
                )
                modelContext.insert(loggedSet)
                exerciseLog.sets.append(loggedSet)
            }
        }

        try modelContext.save()
        return session
    }

    func discard(_ session: WorkoutSession) {
        modelContext.delete(session)
        persistChanges(action: "discard draft")
    }

    func endWithoutProgression(_ session: WorkoutSession, now: Date = .now) {
        session.status = .endedNoProgression
        session.endedAt = now
        persistChanges(action: "end draft without progression")
    }

    func finishWorkoutPreview(for session: WorkoutSession) throws -> FinishWorkoutPreview {
        let progressionsByExerciseKey = try Self.exerciseProgressionsByExerciseKey(from: modelContext)
        let evaluations = evaluate(session, progressionsByExerciseKey: progressionsByExerciseKey)
        let pendingWorkingSetCount = session.exerciseLogs
            .flatMap(\.sets)
            .filter { $0.kind == .working && $0.actualReps == nil }
            .count
        let hasAnyLoggedWorkingSet = session.exerciseLogs
            .flatMap(\.sets)
            .contains { $0.kind == .working && $0.actualReps != nil }
        let nextProgramDay = try Self.nextProgramDay(from: modelContext, after: session, simulatedStatus: .completed)

        return FinishWorkoutPreview(
            perExercise: evaluations.map { evaluation in
                FinishWorkoutPreview.PerExercise(
                    exerciseName: evaluation.exerciseName,
                    setSummary: evaluation.setSummary,
                    oldWeightKg: evaluation.oldWeightKg,
                    newWeightKg: evaluation.newWeightKg,
                    stalledCount: evaluation.stalledCount,
                    state: evaluation.state
                )
            },
            pendingWorkingSetCount: pendingWorkingSetCount,
            canApplyProgression: pendingWorkingSetCount == 0,
            hasAnyLoggedWorkingSet: hasAnyLoggedWorkingSet,
            nextProgramDayName: nextProgramDay?.name,
            nextProgramExerciseNames: nextProgramDay?.orderedSlots.compactMap { $0.exerciseProgression?.exercise?.name } ?? []
        )
    }

    func finalize(_ session: WorkoutSession, now: Date = .now) throws -> FinalizeResult {
        let pendingWorkingSetCount = session.exerciseLogs
            .flatMap(\.sets)
            .filter { $0.kind == .working && $0.actualReps == nil }
            .count
        guard pendingWorkingSetCount == 0 else {
            throw DraftSessionError.cannotFinalizeWithPendingSets(count: pendingWorkingSetCount)
        }

        let progressionsByExerciseKey = try Self.exerciseProgressionsByExerciseKey(from: modelContext)
        let evaluations = evaluate(session, progressionsByExerciseKey: progressionsByExerciseKey)
        var perExercise: [FinalizeResult.PerExercise] = []
        perExercise.reserveCapacity(evaluations.count)

        for evaluation in evaluations {
            guard let progression = progressionsByExerciseKey[evaluation.exerciseKey] else { continue }

            switch evaluation.state {
            case .willProgress, .unchanged:
                progression.currentWeightKg = evaluation.newWeightKg
                progression.stalledCount = 0
                progression.lastProgressionAt = now

                if !evaluation.newWeightKg.isApprox(evaluation.oldWeightKg) {
                    let event = ProgressionEvent(
                        exerciseProgression: progression,
                        session: session,
                        oldWeightKg: evaluation.oldWeightKg,
                        newWeightKg: evaluation.newWeightKg,
                        reason: .success,
                        createdAt: now
                    )
                    modelContext.insert(event)
                }
            case .stalled:
                progression.stalledCount += 1
            case .incomplete:
                break
            }

            perExercise.append(.init(
                exerciseName: evaluation.exerciseName,
                oldWeightKg: evaluation.oldWeightKg,
                newWeightKg: evaluation.newWeightKg,
                didProgress: !evaluation.newWeightKg.isApprox(evaluation.oldWeightKg),
                stalledCount: progression.stalledCount
            ))
        }

        session.status = .completed
        session.endedAt = now
        try modelContext.save()

        let orderedExerciseKeys = Self.orderedExerciseKeys(in: session)
        let orderedPerExercise = perExercise.sorted { lhs, rhs in
            let lhsIndex = orderedExerciseKeys.firstIndex(of: lhs.exerciseName) ?? .max
            let rhsIndex = orderedExerciseKeys.firstIndex(of: rhs.exerciseName) ?? .max
            return lhsIndex < rhsIndex
        }
        let nextProgramDayName = try Self.nextProgramDay(from: modelContext, after: session, simulatedStatus: .completed)?.name
        return FinalizeResult(perExercise: orderedPerExercise, nextProgramDayName: nextProgramDayName)
    }

    private func persistChanges(action: String) {
        do {
            try modelContext.save()
        } catch {
            assertionFailure("Failed to \(action): \(error)")
        }
    }

    private static func makeWeightLoading(from modelContext: ModelContext) throws -> WeightLoading {
        let user = try modelContext.fetch(FetchDescriptor<User>()).first
        guard let user else {
            throw DraftSessionError.missingUserConfiguration
        }

        return WeightLoading(barWeightKg: user.barWeightKg, inventory: user.orderedPlates)
    }

    private static func exerciseProgressionsByExerciseKey(from modelContext: ModelContext) throws -> [String: ExerciseProgression] {
        let progressions = try modelContext.fetch(FetchDescriptor<ExerciseProgression>())
        return Dictionary(
            uniqueKeysWithValues: progressions.compactMap { progression in
                progression.exercise.map { ($0.key, progression) }
            }
        )
    }

    private func evaluate(
        _ session: WorkoutSession,
        progressionsByExerciseKey: [String: ExerciseProgression]
    ) -> [ExerciseEvaluation] {
        var groupedLogs: [String: [ExerciseLog]] = [:]
        var orderedExerciseKeys: [String] = []

        for exerciseLog in session.exerciseLogs {
            guard let exerciseKey = exerciseLog.exercise?.key else { continue }
            if groupedLogs[exerciseKey] == nil {
                orderedExerciseKeys.append(exerciseKey)
            }
            groupedLogs[exerciseKey, default: []].append(exerciseLog)
        }

        return orderedExerciseKeys.compactMap { exerciseKey in
            guard
                let exerciseLogs = groupedLogs[exerciseKey],
                let progression = progressionsByExerciseKey[exerciseKey]
            else {
                return nil
            }

            let orderedWorkingSets = exerciseLogs
                .flatMap(\.sets)
                .filter { $0.kind == .working }
                .sorted { lhs, rhs in
                    if lhs.log?.id != rhs.log?.id {
                        return lhs.log?.id.uuidString ?? "" < rhs.log?.id.uuidString ?? ""
                    }
                    return lhs.index < rhs.index
                }

            let oldWeightKg = progression.currentWeightKg
            let setSummary = orderedWorkingSets
                .map { set in
                    set.actualReps.map(String.init) ?? "—"
                }
                .joined(separator: ", ")

            if orderedWorkingSets.contains(where: { $0.actualReps == nil }) {
                return ExerciseEvaluation(
                    exerciseKey: exerciseKey,
                    exerciseName: exerciseLogs[0].exerciseNameSnapshot,
                    setSummary: setSummary,
                    oldWeightKg: oldWeightKg,
                    newWeightKg: oldWeightKg,
                    stalledCount: progression.stalledCount,
                    state: .incomplete
                )
            }

            // The user might have changed the working weight mid-session via the exercise +/-
            // buttons (or per-set bumps). We progress from what they actually lifted, not from
            // the saved progression — that lets a manual bump-up *be* the progression and lets a
            // deload still advance from the lower weight.
            let liftedWeightKg = orderedWorkingSets
                .compactMap { $0.actualReps != nil ? $0.weightKg : nil }
                .max() ?? oldWeightKg

            let outcome = Progression.evaluate(
                workingSets: orderedWorkingSets.map { WorkingSetResult(targetReps: $0.targetReps, actualReps: $0.actualReps ?? 0) },
                currentWeightKg: oldWeightKg,
                liftedWeightKg: liftedWeightKg,
                incrementKg: progression.incrementKg,
                weightLoading: weightLoading
            )

            switch outcome {
            case let .advanced(newWeightKg):
                return ExerciseEvaluation(
                    exerciseKey: exerciseKey,
                    exerciseName: exerciseLogs[0].exerciseNameSnapshot,
                    setSummary: setSummary,
                    oldWeightKg: oldWeightKg,
                    newWeightKg: newWeightKg,
                    stalledCount: 0,
                    state: newWeightKg.isApprox(oldWeightKg) ? .unchanged : .willProgress
                )
            case .stalled:
                return ExerciseEvaluation(
                    exerciseKey: exerciseKey,
                    exerciseName: exerciseLogs[0].exerciseNameSnapshot,
                    setSummary: setSummary,
                    oldWeightKg: oldWeightKg,
                    newWeightKg: oldWeightKg,
                    stalledCount: progression.stalledCount + 1,
                    state: .stalled
                )
            case .noWorkingSetsLogged:
                return ExerciseEvaluation(
                    exerciseKey: exerciseKey,
                    exerciseName: exerciseLogs[0].exerciseNameSnapshot,
                    setSummary: setSummary,
                    oldWeightKg: oldWeightKg,
                    newWeightKg: oldWeightKg,
                    stalledCount: progression.stalledCount,
                    state: .unchanged
                )
            }
        }
    }

    private static func nextProgramDay(
        from modelContext: ModelContext,
        after session: WorkoutSession,
        simulatedStatus: SessionStatus
    ) throws -> ProgramDay? {
        let days = try modelContext.fetch(FetchDescriptor<ProgramDay>(sortBy: [SortDescriptor(\ProgramDay.orderInRotation)]))
        let simulated = WorkoutSession(
            id: session.id,
            workoutDayID: session.workoutDayID,
            timeZoneIdentifierAtStart: session.timeZoneIdentifierAtStart,
            startedAt: session.startedAt,
            endedAt: session.endedAt,
            programDay: session.programDay ?? ProgramDay(name: "Workout", orderInRotation: 0),
            exerciseLogs: session.exerciseLogs,
            status: simulatedStatus
        )
        return WorkoutScheduler.nextProgramDay(from: days, mostRecentCompleted: simulated)
    }

    private static func orderedExerciseKeys(in session: WorkoutSession) -> [String] {
        session.exerciseLogs.compactMap { $0.exerciseNameSnapshot }
    }
}

private struct ExerciseEvaluation {
    let exerciseKey: String
    let exerciseName: String
    let setSummary: String
    let oldWeightKg: Double
    let newWeightKg: Double
    let stalledCount: Int
    let state: FinishWorkoutPreview.State
}

private extension Double {
    func isApprox(_ other: Double) -> Bool {
        abs(self - other) <= 0.0001
    }
}
