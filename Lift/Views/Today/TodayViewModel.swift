import Foundation
import Observation
import SwiftData

@MainActor
@Observable
final class TodayViewModel {
    var selectedProgramDay: ProgramDay? {
        didSet {
            guard !matchesSelection(selectedProgramDay, oldValue) else { return }
            rebuildDraftPlan()
        }
    }

    private(set) var availableProgramDays: [ProgramDay] = []
    private(set) var draftPlan: DraftSessionPlan?
    private(set) var isLoading = false
    private(set) var isProgramDayLocked = false
    private(set) var programDayLockHint: String?
    private(set) var finishWorkoutPreview: FinishWorkoutPreview?

    var canOpenFinishSheet: Bool {
        finishWorkoutPreview?.hasAnyLoggedWorkingSet ?? false
    }

    var finishWorkoutHint: String? {
        canOpenFinishSheet ? nil : "Log at least one working set to finish"
    }

    @ObservationIgnored
    private var modelContext: ModelContext?
    @ObservationIgnored
    private(set) var weightLoading: WeightLoading?
    @ObservationIgnored
    private var undoCoordinator: UndoCoordinator?
    @ObservationIgnored
    private var restTimer: RestTimerStarting
    private(set) var activeDraftStartedAt: Date?
    private var reopenedDraftID: UUID?
    private var activeDraftSessionID: UUID?
    @ObservationIgnored
    private let clock: () -> Date
    private let timeZone: TimeZone

    private var now: Date { clock() }

    init(
        modelContext: ModelContext? = nil,
        clock: @escaping () -> Date = { Date.now },
        timeZone: TimeZone = .current,
        restTimer: RestTimerStarting = RestTimerStub()
    ) {
        self.modelContext = modelContext
        self.clock = clock
        self.timeZone = timeZone
        self.restTimer = restTimer
    }

    func setModelContext(_ modelContext: ModelContext) {
        self.modelContext = modelContext
    }

    func setReopenedDraftID(_ reopenedDraftID: UUID?) {
        self.reopenedDraftID = reopenedDraftID
    }

    func setUndoCoordinator(_ undoCoordinator: UndoCoordinator) {
        self.undoCoordinator = undoCoordinator
    }

    func setRestTimer(_ restTimer: any RestTimerStarting) {
        self.restTimer = restTimer
    }

    func load() {
        refresh()
    }

    func refresh() {
        guard let modelContext else {
            availableProgramDays = []
            selectedProgramDay = nil
            draftPlan = nil
            isProgramDayLocked = false
            programDayLockHint = nil
            finishWorkoutPreview = nil
            activeDraftStartedAt = nil
            return
        }

        isLoading = true
        defer { isLoading = false }

        do {
            let dayDescriptor = FetchDescriptor<ProgramDay>(sortBy: [SortDescriptor(\ProgramDay.orderInRotation)])
            let sessionDescriptor = FetchDescriptor<WorkoutSession>(
                sortBy: [SortDescriptor(\WorkoutSession.startedAt, order: .reverse)]
            )
            let userDescriptor = FetchDescriptor<User>()

            let days = try modelContext.fetch(dayDescriptor)
            let mostRecentCompleted = try modelContext.fetch(sessionDescriptor).first(where: { $0.status == .completed })
            let user = try modelContext.fetch(userDescriptor).first
            let draftService = try DraftSessionService(modelContext: modelContext)

            availableProgramDays = days
            weightLoading = makeWeightLoading(from: user)

            if let persistedDraft = activeDraftSession(using: draftService) {
                activeDraftSessionID = persistedDraft.id
                selectedProgramDay = matchProgramDay(persistedDraft.programDay, in: days)
                draftPlan = DraftSessionPlan(session: persistedDraft, stalledCounts: stalledCountsByExerciseKey())
                isProgramDayLocked = true
                programDayLockHint = makeProgramDayLockHint(for: persistedDraft)
                finishWorkoutPreview = try draftService.finishWorkoutPreview(for: persistedDraft)
                activeDraftStartedAt = persistedDraft.startedAt
                return
            } else {
                activeDraftSessionID = nil
                isProgramDayLocked = false
                programDayLockHint = nil
                finishWorkoutPreview = nil
                activeDraftStartedAt = nil
            }

            if let currentSelection = selectedProgramDay,
               let refreshedSelection = days.first(where: { matchesSelection($0, currentSelection) }) {
                selectedProgramDay = refreshedSelection
            } else {
                selectedProgramDay = WorkoutScheduler.nextProgramDay(from: days, mostRecentCompleted: mostRecentCompleted)
            }

            if selectedProgramDay == nil {
                draftPlan = nil
            } else {
                rebuildDraftPlan()
            }
        } catch {
            assertionFailure("Failed to load Today screen: \(error)")
            availableProgramDays = []
            selectedProgramDay = nil
            draftPlan = nil
            isProgramDayLocked = false
            programDayLockHint = nil
            finishWorkoutPreview = nil
            activeDraftStartedAt = nil
        }
    }

    func select(day: ProgramDay) {
        guard !isProgramDayLocked else { return }
        guard let matchingDay = availableProgramDays.first(where: { matchesSelection($0, day) }) else {
            return
        }
        selectedProgramDay = matchingDay
    }

    /// Outcome of a user-initiated request to switch to a different ProgramDay
    /// while a draft may already exist.
    enum SwitchOutcome: Equatable {
        /// The requested day is the one already selected. Nothing to do.
        case noChange
        /// The switch was applied immediately (no draft, or empty draft silently discarded).
        case applied
        /// A draft with logged sets exists. Caller should confirm with the user before discarding.
        case requiresConfirmation(loggedSetCount: Int)
        /// The requested day isn't in the program rotation. Nothing happened.
        case unknownDay
    }

    /// Try to switch to `day`. If a draft exists that has logged sets, the caller
    /// must confirm via `confirmDiscardAndSwitch(to:)` before the swap is applied.
    @discardableResult
    func requestSwitch(to day: ProgramDay) -> SwitchOutcome {
        guard let matchingDay = availableProgramDays.first(where: { matchesSelection($0, day) }) else {
            return .unknownDay
        }
        if matchesSelection(selectedProgramDay, matchingDay) {
            return .noChange
        }

        guard isProgramDayLocked else {
            selectedProgramDay = matchingDay
            return .applied
        }

        let logged = loggedSetCount(in: draftPlan)
        if logged == 0 {
            try? discardActiveDraftAndSwitch(to: matchingDay)
            return .applied
        }
        return .requiresConfirmation(loggedSetCount: logged)
    }

    /// Confirm a switch that previously returned `.requiresConfirmation`.
    /// Discards the active draft (and all logged sets) and switches to `day`.
    func confirmDiscardAndSwitch(to day: ProgramDay) throws {
        guard let matchingDay = availableProgramDays.first(where: { matchesSelection($0, day) }) else {
            return
        }
        try discardActiveDraftAndSwitch(to: matchingDay)
    }

    private func discardActiveDraftAndSwitch(to day: ProgramDay) throws {
        guard let modelContext else { return }
        let draftService = try DraftSessionService(modelContext: modelContext)
        if let activeDraftSessionID,
           let draft = draftService.allDrafts().first(where: { $0.id == activeDraftSessionID }) {
            draftService.discard(draft)
        }
        activeDraftSessionID = nil
        reopenedDraftID = nil
        isProgramDayLocked = false
        programDayLockHint = nil
        activeDraftStartedAt = nil
        finishWorkoutPreview = nil
        selectedProgramDay = day
    }

    private func loggedSetCount(in plan: DraftSessionPlan?) -> Int {
        guard let plan else { return 0 }
        return plan.exerciseLogs
            .flatMap(\.sets)
            .filter { $0.actualReps != nil }
            .count
    }

    func prepareDraftIfNeeded() throws -> WorkoutSession? {
        guard let modelContext, let selectedProgramDay else {
            return nil
        }

        let draftService = try DraftSessionService(modelContext: modelContext)
        if let activeDraft = activeDraftSession(using: draftService) {
            return activeDraft
        }

        let session = try draftService.createDraft(
            for: selectedProgramDay,
            now: now,
            calendar: currentCalendar
        )
        // Apply a targeted state update instead of a full refresh: the only thing that changed is
        // that we now have an active draft. Calling refresh() here re-fetches every model, replaces
        // availableProgramDays/weightLoading with fresh instances, and momentarily flips isLoading
        // — together those cause SwiftUI to remount the ScrollView, which jumps the user back to
        // the top of the page on the first tap of the day. syncDraftPlan covers exactly the state
        // that needs to change.
        syncDraftPlan(session: session)
        return session
    }

    @discardableResult
    func tapSet(_ setID: UUID) async throws -> Bool {
        let displayedPlan = draftPlan
        guard let session = try prepareDraftIfNeeded() else { return false }
        guard let (loggedSet, exerciseLog) = resolveSet(id: setID, in: session, displayedPlan: displayedPlan) else { return false }
        let currentState = SetTapStateMachine.state(for: loggedSet.actualReps, targetReps: loggedSet.targetReps)
        let result = SetTapStateMachine.tap(current: currentState, targetReps: loggedSet.targetReps, kind: loggedSet.kind)
        guard result.transition != .noop else { return false }

        let previousReps = loggedSet.actualReps
        apply(transition: result.transition, to: loggedSet)

        let isLoggingWorkingSet = currentState == .pending
            && result.newState == .complete
            && loggedSet.kind == .working

        // Starting the next working set is a clearer "I'm done resting" signal than waiting for the
        // user to tap the rest pill, so cancel any active rest (and its scheduled notification)
        // before we decide whether to start a new one. With the "no rest after the final working
        // set" rule below, this also stops the previous set's timer from firing after the user has
        // moved on.
        if isLoggingWorkingSet {
            await restTimer.skip()
        }

        if shouldStartRest(after: loggedSet, in: exerciseLog, currentState: currentState, newState: result.newState) {
            await restTimer.start(
                exerciseLogID: exerciseLog.id,
                exerciseName: exerciseLog.exerciseNameSnapshot,
                setID: loggedSet.id,
                durationSeconds: restDuration(for: exerciseLog),
                now: loggedSet.completedAt ?? now
            )
        }

        if shouldRecordUndo(from: previousReps, to: loggedSet.actualReps) {
            undoCoordinator?.recordDecrement(
                setID: loggedSet.id,
                description: "\(exerciseLog.exerciseNameSnapshot) set \(loggedSet.index + 1)",
                fromReps: previousReps,
                toReps: loggedSet.actualReps
            )
        }

        try saveChanges()
        syncDraftPlan(session: session)
        return isLoggingWorkingSet
    }

    private func shouldStartRest(
        after loggedSet: LoggedSet,
        in exerciseLog: ExerciseLog,
        currentState: SetCellState,
        newState: SetCellState
    ) -> Bool {
        guard currentState == .pending, newState == .complete else { return false }
        switch loggedSet.kind {
        case .working:
            // The user is moving on to the next exercise — no point counting down a rest they will
            // never wait through. We treat "there's still a pending working set in this exercise"
            // as the signal that more work remains for this lift.
            return exerciseLog.sets.contains { other in
                other.kind == .working && other.id != loggedSet.id && other.actualReps == nil
            }
        case .warmup:
            let warmups = exerciseLog.sets.filter { $0.kind == .warmup }
            return warmups.allSatisfy { $0.actualReps != nil }
        }
    }

    func restoreSet(_ setID: UUID, actualReps: Int?) throws {
        let displayedPlan = draftPlan
        guard let session = try prepareDraftIfNeeded() else { return }
        guard let (loggedSet, _) = resolveSet(id: setID, in: session, displayedPlan: displayedPlan) else { return }

        loggedSet.actualReps = actualReps
        loggedSet.completedAt = actualReps == nil ? nil : (loggedSet.completedAt ?? now)

        try saveChanges()
        syncDraftPlan(session: session)
    }

    func editWeight(forExerciseLog exerciseLogID: UUID, newWeightKg: Double) throws {
        let displayedPlan = draftPlan
        guard let session = try prepareDraftIfNeeded(),
              let exerciseLog = resolveExerciseLog(id: exerciseLogID, in: session, displayedPlan: displayedPlan),
              let weightLoading else {
            return
        }

        let snappedWeight = weightLoading.nearestLoadable(newWeightKg)
        exerciseLog.targetWeightKgSnapshot = snappedWeight

        for set in exerciseLog.sets where set.kind == .working && set.actualReps == nil {
            set.weightKg = snappedWeight
        }

        let completedWarmups = exerciseLog.sets
            .filter { $0.kind == .warmup && $0.actualReps != nil }
            .sorted { $0.index < $1.index }
        let pendingWarmups = exerciseLog.sets
            .filter { $0.kind == .warmup && $0.actualReps == nil }
            .sorted { $0.index < $1.index }

        let warmupCalculator = WarmupCalculator(weightLoading: weightLoading)
        let policy = exerciseLog.exercise?.warmupPolicy ?? .default
        let recomputedWarmups = warmupCalculator.warmupSets(
            forWorkingWeightKg: snappedWeight,
            policy: policy
        )
        let updatedWarmups = Array(
            recomputedWarmups.dropFirst(min(completedWarmups.count, recomputedWarmups.count))
        )

        reindex(completedWarmups)
        try replacePendingWarmups(
            pendingWarmups,
            with: updatedWarmups,
            in: exerciseLog
        )

        try saveChanges()
        syncDraftPlan(session: session)
    }

    func editWeight(forSet setID: UUID, newWeightKg: Double) throws {
        let displayedPlan = draftPlan
        guard let session = try prepareDraftIfNeeded(),
              let (loggedSet, _) = resolveSet(id: setID, in: session, displayedPlan: displayedPlan),
              let weightLoading else {
            return
        }

        loggedSet.weightKg = weightLoading.nearestLoadable(newWeightKg)
        try saveChanges()
        syncDraftPlan(session: session)
    }

    func editReps(forSet setID: UUID, targetReps: Int) throws {
        let displayedPlan = draftPlan
        guard let session = try prepareDraftIfNeeded(),
              let (loggedSet, _) = resolveSet(id: setID, in: session, displayedPlan: displayedPlan) else {
            return
        }

        loggedSet.targetReps = max(1, targetReps)
        try saveChanges()
        syncDraftPlan(session: session)
    }

    func addWarmupSet(toExerciseLogID exerciseLogID: UUID) throws {
        let displayedPlan = draftPlan
        guard let modelContext,
              let session = try prepareDraftIfNeeded(),
              let exerciseLog = resolveExerciseLog(id: exerciseLogID, in: session, displayedPlan: displayedPlan),
              let weightLoading else {
            return
        }

        let workingWeight = exerciseLog.targetWeightKgSnapshot
        let policy = exerciseLog.exercise?.warmupPolicy ?? .default
        let warmupLoading = weightLoading.filtered(minimumPlateKg: policy.minimumWarmupPlateKg)
        let warmups = exerciseLog.sets.filter { $0.kind == .warmup }.sorted { $0.index < $1.index }

        let newWeight: Double
        let newReps: Int
        if let last = warmups.last {
            if let next = warmupLoading.nextHigherLoadable(last.weightKg), next < workingWeight {
                newWeight = next
            } else {
                newWeight = last.weightKg
            }
            newReps = 3
        } else if policy.includesBarWarmup {
            newWeight = weightLoading.barWeightKg
            newReps = 5
        } else {
            guard let firstLoaded = warmupLoading.nextHigherLoadable(weightLoading.barWeightKg),
                  firstLoaded < workingWeight else {
                return
            }
            newWeight = firstLoaded
            newReps = 5
        }

        let newSet = LoggedSet(
            log: exerciseLog,
            kind: .warmup,
            index: warmups.count,
            weightKg: newWeight,
            targetReps: newReps
        )
        modelContext.insert(newSet)
        exerciseLog.sets.append(newSet)
        try saveChanges()
        syncDraftPlan(session: session)
    }

    func deleteSet(_ setID: UUID) throws {
        let displayedPlan = draftPlan
        guard let modelContext, let session = try prepareDraftIfNeeded(),
              let (loggedSet, exerciseLog) = resolveSet(id: setID, in: session, displayedPlan: displayedPlan) else {
            return
        }

        exerciseLog.sets.removeAll { $0.id == setID }
        modelContext.delete(loggedSet)
        reindex(exerciseLog.sets.filter { $0.kind == loggedSet.kind }.sorted { $0.index < $1.index })

        try saveChanges()
        syncDraftPlan(session: session)
    }

    private func rebuildDraftPlan() {
        guard let selectedProgramDay, let weightLoading else {
            draftPlan = nil
            return
        }

        let warmupCalculator = WarmupCalculator(weightLoading: weightLoading)
        draftPlan = DraftSessionFactory.makeDraft(
            programDay: selectedProgramDay,
            startedAt: now,
            timeZone: timeZone,
            warmupCalculator: warmupCalculator
        )
    }

    private func makeWeightLoading(from user: User?) -> WeightLoading? {
        guard let user else { return nil }
        return WeightLoading(barWeightKg: user.barWeightKg, inventory: user.orderedPlates)
    }

    private func apply(transition: SetTapTransition, to loggedSet: LoggedSet) {
        switch transition {
        case let .persist(newReps):
            loggedSet.actualReps = newReps
            loggedSet.completedAt = newReps == nil ? nil : (loggedSet.completedAt ?? now)
        case .persistPending:
            loggedSet.actualReps = nil
            loggedSet.completedAt = nil
        case .noop:
            break
        }
    }

    private var currentCalendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        return calendar
    }

    private func activeDraftSession(using draftService: DraftSessionService) -> WorkoutSession? {
        if let reopenedDraftID {
            if let reopened = draftService.allDrafts().first(where: { $0.id == reopenedDraftID }) {
                return reopened
            }
            self.reopenedDraftID = nil
        }

        return draftService.currentDraft(now: now, calendar: currentCalendar)
    }

    private func matchProgramDay(_ programDay: ProgramDay?, in days: [ProgramDay]) -> ProgramDay? {
        guard let programDay else { return nil }
        return days.first(where: { matchesSelection($0, programDay) }) ?? programDay
    }

    private func syncDraftPlan(session: WorkoutSession) {
        activeDraftSessionID = session.id
        reopenedDraftID = session.id
        selectedProgramDay = matchProgramDay(session.programDay, in: availableProgramDays)
        draftPlan = DraftSessionPlan(session: session, stalledCounts: stalledCountsByExerciseKey())
        activeDraftStartedAt = session.startedAt
        isProgramDayLocked = true
        programDayLockHint = makeProgramDayLockHint(for: session)
        if let modelContext, let draftService = try? DraftSessionService(modelContext: modelContext) {
            finishWorkoutPreview = try? draftService.finishWorkoutPreview(for: session)
        } else {
            finishWorkoutPreview = nil
        }
    }

    private func stalledCountsByExerciseKey() -> [String: Int] {
        guard let modelContext,
              let progressions = try? modelContext.fetch(FetchDescriptor<ExerciseProgression>()) else {
            return [:]
        }
        return Dictionary(uniqueKeysWithValues: progressions.compactMap { progression in
            guard let key = progression.exercise?.key else { return nil }
            return (key, progression.stalledCount)
        })
    }

    private func makeProgramDayLockHint(for session: WorkoutSession) -> String {
        let dayName = session.programDay?.name ?? selectedProgramDay?.name ?? "Workout"
        let todayID = LocalDay.id(for: now, in: timeZone)
        if session.workoutDayID == todayID {
            return "\(dayName) — in progress. Tap to switch."
        }
        return "\(dayName) — unfinished draft. Tap to switch."
    }

    private func matchesSelection(_ lhs: ProgramDay?, _ rhs: ProgramDay?) -> Bool {
        switch (lhs?.persistentModelID, rhs?.persistentModelID) {
        case let (left?, right?):
            return left == right
        case (nil, nil):
            return true
        default:
            return false
        }
    }

    private static func formatWeight(_ weight: Double) -> String {
        weight.formatted(.number.precision(.fractionLength(weight.rounded(.down) == weight ? 0 : 1)))
    }

    private func saveChanges() throws {
        try modelContext?.save()
    }

    private func findSet(id setID: UUID, in session: WorkoutSession) -> (LoggedSet, ExerciseLog)? {
        for exerciseLog in session.exerciseLogs {
            if let loggedSet = exerciseLog.sets.first(where: { $0.id == setID }) {
                return (loggedSet, exerciseLog)
            }
        }
        return nil
    }

    private func resolveSet(id setID: UUID, in session: WorkoutSession, displayedPlan: DraftSessionPlan?) -> (LoggedSet, ExerciseLog)? {
        if let match = findSet(id: setID, in: session) {
            return match
        }

        guard let displayedPlan,
              let displayedLog = displayedPlan.exerciseLogs.first(where: { log in
                  log.sets.contains(where: { $0.id == setID })
              }),
              let displayedSet = displayedLog.sets.first(where: { $0.id == setID }),
              let exerciseLog = resolveExerciseLog(id: displayedLog.id, in: session, displayedPlan: displayedPlan) else {
            return nil
        }

        guard let loggedSet = exerciseLog.sets.first(where: { $0.kind == displayedSet.kind && $0.index == displayedSet.index }) else {
            return nil
        }
        return (loggedSet, exerciseLog)
    }

    private func resolveExerciseLog(id exerciseLogID: UUID, in session: WorkoutSession, displayedPlan: DraftSessionPlan?) -> ExerciseLog? {
        if let exact = session.exerciseLogs.first(where: { $0.id == exerciseLogID }) {
            return exact
        }

        guard let displayedPlan,
              let displayedLog = displayedPlan.exerciseLogs.first(where: { $0.id == exerciseLogID }) else {
            return nil
        }

        if let exerciseKey = displayedLog.exercise?.key,
           let match = session.exerciseLogs.first(where: { $0.exercise?.key == exerciseKey }) {
            return match
        }

        return session.exerciseLogs.first(where: { $0.exerciseNameSnapshot == displayedLog.exerciseNameSnapshot })
    }

    private func reindex(_ sets: [LoggedSet]) {
        for (index, set) in sets.enumerated() {
            set.index = index
        }
    }

    private func replacePendingWarmups(
        _ existingWarmups: [LoggedSet],
        with updatedWarmups: [(weightKg: Double, reps: Int)],
        in exerciseLog: ExerciseLog
    ) throws {
        guard let modelContext else { return }

        for (offset, warmup) in updatedWarmups.enumerated() {
            if offset < existingWarmups.count {
                let set = existingWarmups[offset]
                set.weightKg = warmup.weightKg
                set.targetReps = warmup.reps
                set.index = offset + exerciseLog.sets.filter { $0.kind == .warmup && $0.actualReps != nil }.count
            } else {
                let newSet = LoggedSet(
                    log: exerciseLog,
                    kind: .warmup,
                    index: offset + exerciseLog.sets.filter { $0.kind == .warmup && $0.actualReps != nil }.count,
                    weightKg: warmup.weightKg,
                    targetReps: warmup.reps
                )
                modelContext.insert(newSet)
                exerciseLog.sets.append(newSet)
            }
        }

        if existingWarmups.count > updatedWarmups.count {
            for set in existingWarmups.dropFirst(updatedWarmups.count) {
                exerciseLog.sets.removeAll { $0.id == set.id }
                modelContext.delete(set)
            }
        }
    }

    private func shouldRecordUndo(from oldReps: Int?, to newReps: Int?) -> Bool {
        switch (oldReps, newReps) {
        case let (old?, new?):
            return new < old
        case (.some, nil):
            return true
        default:
            return false
        }
    }

    func finalizeCurrentSession() throws -> FinalizeResult {
        guard let modelContext else {
            return FinalizeResult(perExercise: [], nextProgramDayName: nil)
        }

        let draftService = try DraftSessionService(modelContext: modelContext)
        guard let session = activeDraftSession(using: draftService) else {
            return FinalizeResult(perExercise: [], nextProgramDayName: nil)
        }

        let result = try draftService.finalize(session, now: now)
        activeDraftSessionID = nil
        reopenedDraftID = nil
        selectedProgramDay = nil
        activeDraftStartedAt = nil
        refresh()
        return result
    }

    func endCurrentSessionWithoutProgression() throws {
        guard let modelContext else { return }

        let draftService = try DraftSessionService(modelContext: modelContext)
        guard let session = activeDraftSession(using: draftService) else { return }

        draftService.endWithoutProgression(session, now: now)
        activeDraftSessionID = nil
        reopenedDraftID = nil
        selectedProgramDay = nil
        activeDraftStartedAt = nil
        refresh()
    }

    private func restDuration(for exerciseLog: ExerciseLog) -> Int {
        guard let modelContext else {
            return 0
        }
        guard let exerciseKey = exerciseLog.exercise?.key else {
            return 0
        }
        return (try? modelContext.fetch(FetchDescriptor<ExerciseProgression>())
            .first(where: { $0.exercise?.key == exerciseKey })?.restSeconds) ?? 0
    }
}

@MainActor
protocol RestTimerStarting {
    func start(exerciseLogID: UUID, exerciseName: String, setID: UUID, durationSeconds: Int, now: Date) async
    func skip() async
}

@MainActor
struct RestTimerStub: RestTimerStarting {
    func start(exerciseLogID _: UUID, exerciseName _: String, setID _: UUID, durationSeconds _: Int, now _: Date) async {}
    func skip() async {}
}
