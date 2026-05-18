import SwiftData
import SwiftUI

struct TodayView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.haptics) private var haptics
    @Environment(\.restTimer) private var restTimer
    @State private var viewModel = TodayViewModel()
    @State private var undoCoordinator = UndoCoordinator()
    @State private var isShowingFinishSheet = false
    @State private var errorMessage: String?
    @State private var confettiTrigger = 0
    let draftReopenCoordinator: DraftReopenCoordinator

    @State private var pendingSwitchTarget: PendingSwitchTarget?

    private struct PendingSwitchTarget: Identifiable {
        let id = UUID()
        let day: ProgramDay
        let loggedSetCount: Int
    }

    var body: some View {
        NavigationStack {
            Group {
                if let draftPlan = viewModel.draftPlan {
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 16) {
                            header

                            ForEach(draftPlan.exerciseLogs, id: \.id) { exerciseLog in
                                TodayExerciseCard(
                                    exerciseLog: exerciseLog,
                                    weightLoading: viewModel.weightLoading,
                                    onTapSet: { setID in
                                        performAsync { try await viewModel.tapSet(setID) }
                                    },
                                    onEditWorkingWeight: { newWeight in
                                        perform { try viewModel.editWeight(forExerciseLog: exerciseLog.id, newWeightKg: newWeight) }
                                    },
                                    onEditSetWeight: { setID, newWeight in
                                        perform { try viewModel.editWeight(forSet: setID, newWeightKg: newWeight) }
                                    },
                                    onEditSetReps: { setID, newReps in
                                        perform { try viewModel.editReps(forSet: setID, targetReps: newReps) }
                                    },
                                    onDeleteSet: { setID in
                                        perform { try viewModel.deleteSet(setID) }
                                    },
                                    onAddWarmup: {
                                        perform { try viewModel.addWarmupSet(toExerciseLogID: exerciseLog.id) }
                                    }
                                )
                            }

                            footer
                        }
                        .padding(.horizontal, 20)
                        .padding(.vertical, 24)
                    }
                    .background(LiftTheme.canvas)
                } else if viewModel.isLoading {
                    ProgressView("Loading today’s workout…")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ContentUnavailableView(
                        "No program configured",
                        systemImage: "figure.strengthtraining.traditional",
                        description: Text("Finish setup to see today’s workout.")
                    )
                }
            }
            .navigationTitle("Today")
            .task(id: draftReopenCoordinator.refreshToken) {
                viewModel.setModelContext(modelContext)
                viewModel.setReopenedDraftID(draftReopenCoordinator.resumedDraftID)
                viewModel.setUndoCoordinator(undoCoordinator)
                if let restTimer {
                    viewModel.setRestTimer(restTimer)
                    restTimer.setModelContext(modelContext)
                }
                viewModel.load()
            }
            .safeAreaInset(edge: .bottom) {
                if let snackbar = undoCoordinator.currentSnackbar {
                    SnackbarView(message: snackbar.message, actionTitle: "Undo") {
                        guard let action = undoCoordinator.undo() else { return }
                        perform { try viewModel.restoreSet(action.setID, actualReps: action.restoreReps) }
                    }
                    .padding(.horizontal, 20)
                    .padding(.bottom, 8)
                }
            }
            .task(id: undoCoordinator.currentSnackbar?.id) {
                guard undoCoordinator.currentSnackbar != nil else { return }
                try? await Task.sleep(for: .seconds(4))
                undoCoordinator.tick()
            }
            .sheet(isPresented: $isShowingFinishSheet) {
                if let preview = viewModel.finishWorkoutPreview {
                    FinishWorkoutSheet(
                        preview: preview,
                        onFinish: {
                            perform {
                                _ = try viewModel.finalizeCurrentSession()
                                haptics.workoutFinished()
                                confettiTrigger += 1
                                draftReopenCoordinator.presentConfirmation("Progression applied")
                            }
                            isShowingFinishSheet = false
                        },
                        onEndWithoutProgression: {
                            perform {
                                try viewModel.endCurrentSessionWithoutProgression()
                                haptics.workoutFinished()
                                draftReopenCoordinator.presentConfirmation("Workout ended without progression")
                            }
                            isShowingFinishSheet = false
                        },
                        onCancel: {
                            isShowingFinishSheet = false
                        }
                    )
                }
            }
            .alert("Something went wrong", isPresented: errorAlertBinding) {
                Button("OK", role: .cancel) { errorMessage = nil }
            } message: {
                Text(errorMessage ?? "")
            }
            .confirmationDialog(
                discardSwitchTitle,
                isPresented: switchAlertBinding,
                titleVisibility: .visible,
                presenting: pendingSwitchTarget
            ) { target in
                Button("Discard and switch", role: .destructive) {
                    perform { try viewModel.confirmDiscardAndSwitch(to: target.day) }
                    pendingSwitchTarget = nil
                }
                Button("Keep current workout", role: .cancel) {
                    pendingSwitchTarget = nil
                }
            } message: { target in
                Text("This deletes \(target.loggedSetCount) logged \(target.loggedSetCount == 1 ? "set" : "sets") in your current workout.")
            }
        }
        .overlay {
            ConfettiOverlay(trigger: confettiTrigger)
                .ignoresSafeArea()
        }
    }

    private func handleWorkoutPick(_ day: ProgramDay) {
        switch viewModel.requestSwitch(to: day) {
        case .noChange, .applied, .unknownDay:
            break
        case let .requiresConfirmation(loggedSetCount):
            pendingSwitchTarget = PendingSwitchTarget(day: day, loggedSetCount: loggedSetCount)
        }
    }

    private var switchAlertBinding: Binding<Bool> {
        Binding(
            get: { pendingSwitchTarget != nil },
            set: { newValue in
                if !newValue { pendingSwitchTarget = nil }
            }
        )
    }

    private var discardSwitchTitle: String {
        guard let target = pendingSwitchTarget else { return "" }
        return "Switch to \(target.day.name)?"
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 12) {
            WorkoutPicker(
                selectedDayName: viewModel.selectedProgramDay?.name ?? "Choose workout",
                availableProgramDays: viewModel.availableProgramDays,
                isLocked: viewModel.isProgramDayLocked,
                onSelect: handleWorkoutPick(_:)
            )

            HStack(spacing: 14) {
                Label(Date.now.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated).year()), systemImage: "calendar")
                    .labelStyle(.titleAndIcon)
                    .font(.subheadline)
                    .foregroundStyle(LiftTheme.textSecondary)

                if viewModel.activeDraftStartedAt != nil {
                    Text("•")
                        .foregroundStyle(LiftTheme.textTertiary)
                }

                if let startedAt = viewModel.activeDraftStartedAt {
                    TimelineView(.periodic(from: .now, by: 1)) { context in
                        let elapsed = formattedElapsed(since: startedAt, now: context.date)
                        Label(elapsed, systemImage: "clock")
                            .labelStyle(.titleAndIcon)
                            .font(.subheadline)
                            .monospacedDigit()
                            .foregroundStyle(LiftTheme.textSecondary)
                            .accessibilityLabel("Workout elapsed time")
                            .accessibilityValue(elapsed)
                    }
                }
            }
        }
        .padding(.bottom, 4)
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button("Finish workout") {
                isShowingFinishSheet = true
            }
                .buttonStyle(.borderedProminent)
                .disabled(!viewModel.canOpenFinishSheet)
                .frame(maxWidth: .infinity)

            if let hint = viewModel.finishWorkoutHint {
                Text(hint)
                    .font(.caption)
                    .foregroundStyle(LiftTheme.textSecondary)
                    .frame(maxWidth: .infinity, alignment: .center)
            }
        }
        .padding(.top, 8)
        .padding(.bottom, 24)
    }

    private func perform(_ action: () throws -> Void) {
        do {
            try action()
        } catch {
            errorMessage = describe(error)
        }
    }

    private func performAsync(_ action: @escaping () async throws -> Void) {
        Task {
            do {
                try await action()
            } catch {
                errorMessage = describe(error)
            }
        }
    }

    private func performAsync(_ action: @escaping () async throws -> Bool) {
        Task {
            do {
                if try await action() {
                    haptics.workingSetCompleted()
                }
            } catch {
                errorMessage = describe(error)
            }
        }
    }

    private var errorAlertBinding: Binding<Bool> {
        Binding(
            get: { errorMessage != nil },
            set: { newValue in if !newValue { errorMessage = nil } }
        )
    }

    private func describe(_ error: Error) -> String {
        if let localized = error as? LocalizedError, let description = localized.errorDescription {
            return description
        }
        return error.localizedDescription
    }

    private func formattedElapsed(since startedAt: Date, now: Date) -> String {
        let totalSeconds = max(0, Int(now.timeIntervalSince(startedAt)))
        let hours = totalSeconds / 3600
        let minutes = (totalSeconds % 3600) / 60
        let seconds = totalSeconds % 60

        if hours > 0 {
            return "\(hours):\(minutes.formatted(.number.precision(.integerLength(2)))):\(seconds.formatted(.number.precision(.integerLength(2))))"
        }
        return "\(minutes.formatted(.number.precision(.integerLength(2)))):\(seconds.formatted(.number.precision(.integerLength(2))))"
    }
}

private struct FinishWorkoutSheet: View {
    let preview: FinishWorkoutPreview
    let onFinish: () -> Void
    let onEndWithoutProgression: () -> Void
    let onCancel: () -> Void

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 20) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Finish workout?")
                        .font(.title2.weight(.semibold))

                    if preview.pendingWorkingSetCount > 0 {
                        Text("\(preview.pendingWorkingSetCount) working sets not yet logged")
                            .font(.subheadline.weight(.medium))
                            .foregroundStyle(.orange)
                    }
                }

                DraftFinishPreviewSummary(preview: preview, compact: false)

                Spacer(minLength: 0)

                VStack(spacing: 10) {
                    Button(action: onFinish) {
                        Text("Finish & apply progression")
                            .frame(maxWidth: .infinity)
                    }
                    .controlSize(.large)
                    .buttonStyle(.borderedProminent)
                    .disabled(!preview.canApplyProgression)

                    Button(action: onEndWithoutProgression) {
                        Text("End without progression")
                            .frame(maxWidth: .infinity)
                    }
                    .controlSize(.large)
                    .buttonStyle(.bordered)

                    Button("Cancel", role: .cancel, action: onCancel)
                        .controlSize(.large)
                        .frame(maxWidth: .infinity)
                        .padding(.top, 4)
                }
            }
            .padding(24)
            .navigationBarTitleDisplayMode(.inline)
        }
    }
}

struct DraftFinishPreviewSummary: View {
    let preview: FinishWorkoutPreview
    let compact: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(Array(preview.perExercise.enumerated()), id: \.offset) { _, exercise in
                VStack(alignment: .leading, spacing: 4) {
                    if !compact {
                        Text(exercise.setSummary.isEmpty ? "—" : exercise.setSummary)
                            .font(.caption)
                            .foregroundStyle(LiftTheme.textSecondary)
                    }

                    Text(compact ? compactLine(for: exercise) : detailLine(for: exercise))
                        .font(.subheadline)
                        .foregroundStyle(LiftTheme.textPrimary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 4)
            }

            if let nextProgramDayName = preview.nextProgramDayName {
                Text(nextSummary(dayName: nextProgramDayName, exerciseNames: preview.nextProgramExerciseNames))
                    .font(.footnote.weight(.medium))
                    .foregroundStyle(LiftTheme.textSecondary)
                    .padding(.top, 4)
            }
        }
        .padding(16)
        .background(LiftTheme.card, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(LiftTheme.cardBorder, lineWidth: 1)
        )
    }

    private func detailLine(for exercise: FinishWorkoutPreview.PerExercise) -> String {
        switch exercise.state {
        case .incomplete:
            return "\(exercise.exerciseName) — incomplete"
        case .willProgress:
            return "\(exercise.exerciseName) \(formatted(exercise.oldWeightKg)) → \(formatted(exercise.newWeightKg)) kg"
        case .stalled:
            return "\(exercise.exerciseName) \(formatted(exercise.oldWeightKg)) kg (stalled, \(sessionLabel(exercise.stalledCount)))"
        case .unchanged:
            return "\(exercise.exerciseName) \(formatted(exercise.oldWeightKg)) kg (load unchanged)"
        }
    }

    private func compactLine(for exercise: FinishWorkoutPreview.PerExercise) -> String {
        switch exercise.state {
        case .incomplete:
            return "\(exercise.exerciseName) — incomplete"
        case .willProgress:
            return "\(exercise.exerciseName) \(formatted(exercise.oldWeightKg)) → \(formatted(exercise.newWeightKg))"
        case .stalled:
            return "\(exercise.exerciseName) \(formatted(exercise.oldWeightKg)) stalled"
        case .unchanged:
            return "\(exercise.exerciseName) \(formatted(exercise.oldWeightKg)) unchanged"
        }
    }

    private func nextSummary(dayName: String, exerciseNames: [String]) -> String {
        guard !exerciseNames.isEmpty else { return "Next time: \(dayName)" }
        return "Next time: \(dayName) — \(exerciseNames.joined(separator: ", "))"
    }

    private func formatted(_ weight: Double) -> String {
        weight.formatted(.number.precision(.fractionLength(1)))
    }

    private func sessionLabel(_ count: Int) -> String {
        count == 1 ? "1 session" : "\(count) sessions"
    }
}

#Preview {
    TodayView(draftReopenCoordinator: DraftReopenCoordinator())
        .modelContainer(PreviewSupport.container)
}
