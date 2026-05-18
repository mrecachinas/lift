import SwiftUI

struct TodayExerciseCard: View {
    let exerciseLog: DraftExerciseLog
    let weightLoading: WeightLoading?
    let onTapSet: (UUID) -> Void
    let onEditWorkingWeight: (Double) -> Void
    let onEditSetWeight: (UUID, Double) -> Void
    let onEditSetReps: (UUID, Int) -> Void
    let onDeleteSet: (UUID) -> Void
    let onAddWarmup: () -> Void

    @State private var isShowingWarmups = false
    @State private var hasInitializedWarmupExpansion = false
    @State private var hasUserToggledWarmupExpansion = false
    @State private var isShowingWorkingWeightEditor = false
    @State private var isShowingPlateCalculator = false

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            headerRow

            Divider().background(LiftTheme.cardBorder)

            warmupSection

            Divider().background(LiftTheme.cardBorder)

            workingSection
        }
        .padding(20)
        .background(LiftTheme.card, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .strokeBorder(LiftTheme.cardBorder, lineWidth: 1)
        )
        .sheet(isPresented: $isShowingWorkingWeightEditor) {
            WeightEditorSheet(
                title: "Edit working weight",
                initialWeightKg: exerciseLog.targetWeightKgSnapshot,
                onCommit: onEditWorkingWeight,
                weightLoading: weightLoading
            )
        }
        .sheet(isPresented: $isShowingPlateCalculator) {
            if let weightLoading {
                PlateCalculatorSheet(
                    initialWeightKg: exerciseLog.targetWeightKgSnapshot,
                    weightLoading: weightLoading,
                    onUseWeight: onEditWorkingWeight
                )
            }
        }
        .onAppear {
            guard !hasInitializedWarmupExpansion else { return }
            hasInitializedWarmupExpansion = true
            isShowingWarmups = !warmupSets.isEmpty && !allWarmupsComplete
        }
        .onChange(of: allWarmupsComplete) { _, isComplete in
            guard isComplete, !hasUserToggledWarmupExpansion, isShowingWarmups else { return }
            withAnimation(.easeInOut) {
                isShowingWarmups = false
            }
        }
    }

    private var headerRow: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 6) {
                Text(exerciseLog.exerciseNameSnapshot)
                    .font(.title2.weight(.bold))
                    .foregroundStyle(LiftTheme.textPrimary)

                HStack(spacing: 8) {
                    Text("\(exerciseLog.targetSetsSnapshot) × \(exerciseLog.targetRepsSnapshot)")
                        .font(.subheadline)
                        .foregroundStyle(LiftTheme.textSecondary)

                    if exerciseLog.stalledCount > 0 {
                        stalledBadge
                    }
                }

                if let platesLine {
                    Button {
                        guard weightLoading != nil else { return }
                        isShowingPlateCalculator = true
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "rectangle.stack")
                                .font(.caption2.weight(.semibold))
                            Text(platesLine)
                                .font(.caption.weight(.medium))
                                .lineLimit(1)
                        }
                        .foregroundStyle(LiftTheme.accent)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Plates per side: \(platesLine). Tap for plate calculator.")
                    .disabled(weightLoading == nil)
                }
            }

            Spacer(minLength: 12)

            Button {
                isShowingWorkingWeightEditor = true
            } label: {
                HStack(spacing: 6) {
                    HStack(alignment: .firstTextBaseline, spacing: 4) {
                        Text(formattedWeight)
                            .font(.title.weight(.bold))
                            .foregroundStyle(LiftTheme.accent)
                        Text("kg")
                            .font(.subheadline.weight(.medium))
                            .foregroundStyle(LiftTheme.textSecondary)
                    }
                    Image(systemName: "pencil")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(LiftTheme.textSecondary)
                        .padding(8)
                        .background(LiftTheme.raisedFill, in: Circle())
                }
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Edit working weight, currently \(formattedWeight) kilograms")
        }
    }

    private var stalledBadge: some View {
        let count = exerciseLog.stalledCount
        return Text("Stalled ×\(count)")
            .font(.caption2.weight(.bold))
            .foregroundStyle(LiftTheme.warning)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(LiftTheme.warning.opacity(0.18), in: Capsule())
            .overlay(Capsule().strokeBorder(LiftTheme.warning.opacity(0.45), lineWidth: 1))
            .accessibilityLabel("Stalled \(count) session\(count == 1 ? "" : "s")")
    }

    private var platesLine: String? {
        guard let weightLoading else { return nil }
        switch weightLoading.plates(for: exerciseLog.targetWeightKgSnapshot) {
        case let .exact(perSidePlatesKg):
            guard !perSidePlatesKg.isEmpty else { return nil }
            return formatPlates(perSidePlatesKg)
        case .closest:
            return nil
        }
    }

    private func formatPlates(_ plates: [Double]) -> String {
        let counts = plates.reduce(into: [(Double, Int)]()) { acc, plate in
            if let last = acc.last, last.0 == plate {
                acc[acc.count - 1] = (plate, last.1 + 1)
            } else {
                acc.append((plate, 1))
            }
        }
        return counts.map { plate, count in
            "\(count)×\(formatPlateWeight(plate))"
        }.joined(separator: " + ")
    }

    private func formatPlateWeight(_ weight: Double) -> String {
        weight.formatted(
            .number.precision(.fractionLength(weight.rounded(.down) == weight ? 0 : 2))
        )
    }

    private var warmupSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionHeader(
                title: "Warmup",
                count: warmupSets.count,
                isExpanded: warmupSets.isEmpty ? false : isShowingWarmups,
                isToggleable: !warmupSets.isEmpty
            ) {
                hasUserToggledWarmupExpansion = true
                withAnimation(.easeInOut) {
                    isShowingWarmups.toggle()
                }
            }

            if warmupSets.isEmpty || isShowingWarmups {
                if warmupSets.isEmpty {
                    Text("No warmup sets")
                        .font(.subheadline)
                        .foregroundStyle(LiftTheme.textSecondary)
                } else {
                    warmupSetRow(sets: warmupSets)
                }

                Button {
                    onAddWarmup()
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "plus.circle")
                            .font(.body.weight(.semibold))
                        Text("Add warmup")
                            .font(.subheadline.weight(.semibold))
                    }
                    .foregroundStyle(LiftTheme.accent)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)
                    .frame(maxWidth: .infinity)
                    .background(LiftTheme.accentMuted.opacity(0.5), in: Capsule())
                    .overlay(Capsule().strokeBorder(LiftTheme.accentBorder, lineWidth: 1))
                }
                .buttonStyle(.plain)
            }
        }
    }

    private var workingSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionHeader(
                title: "Working sets",
                count: workingSets.count,
                isExpanded: true,
                isToggleable: false,
                onToggle: nil
            )

            setRow(sets: workingSets, nextUpID: nextUpWorkingSetID)
        }
    }

    @ViewBuilder
    private func setRow(sets: [DraftSet], nextUpID: UUID?) -> some View {
        HStack(alignment: .top, spacing: 8) {
            ForEach(sets, id: \.id) { set in
                TodaySetTile(
                    set: set,
                    isNextUp: set.id == nextUpID,
                    hidesTargetReps: set.kind == .working
                        && set.targetReps == exerciseLog.targetRepsSnapshot,
                    onTap: { onTapSet(set.id) },
                    onEditWeight: { onEditSetWeight(set.id, $0) },
                    onEditReps: set.kind == .warmup ? { onEditSetReps(set.id, $0) } : nil,
                    onDelete: { onDeleteSet(set.id) },
                    weightLoading: weightLoading
                )
            }
        }
    }

    @ViewBuilder
    private func warmupSetRow(sets: [DraftSet]) -> some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .top, spacing: 8) {
                ForEach(sets, id: \.id) { set in
                    warmupTile(for: set)
                        .frame(minWidth: 90)
                }
            }

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(alignment: .top, spacing: 8) {
                    ForEach(sets, id: \.id) { set in
                        warmupTile(for: set)
                            .frame(width: 110)
                    }
                }
                .padding(.trailing, 4)
            }
            .scrollClipDisabled()
        }
    }

    private func warmupTile(for set: DraftSet) -> some View {
        TodaySetTile(
            set: set,
            isNextUp: false,
            onTap: { onTapSet(set.id) },
            onEditWeight: { onEditSetWeight(set.id, $0) },
            onEditReps: { onEditSetReps(set.id, $0) },
            onDelete: { onDeleteSet(set.id) },
            weightLoading: weightLoading
        )
    }

    private var warmupSets: [DraftSet] {
        exerciseLog.sets.filter { $0.kind == .warmup }
    }

    private var workingSets: [DraftSet] {
        exerciseLog.sets.filter { $0.kind == .working }
    }

    private var nextUpWorkingSetID: UUID? {
        workingSets.first { set in
            SetTapStateMachine.state(for: set.actualReps, targetReps: set.targetReps) == .pending
        }?.id
    }

    private var allWarmupsComplete: Bool {
        guard !warmupSets.isEmpty else { return false }
        return warmupSets.allSatisfy { set in
            SetTapStateMachine.state(for: set.actualReps, targetReps: set.targetReps) == .complete
        }
    }

    private var formattedWeight: String {
        exerciseLog.targetWeightKgSnapshot.formatted(
            .number.precision(.fractionLength(exerciseLog.targetWeightKgSnapshot.rounded(.down) == exerciseLog.targetWeightKgSnapshot ? 0 : 1))
        )
    }

    private func completedCount(in sets: [DraftSet]) -> Int {
        sets.reduce(into: 0) { count, set in
            if SetTapStateMachine.state(for: set.actualReps, targetReps: set.targetReps) == .complete {
                count += 1
            }
        }
    }

    @ViewBuilder
    private func sectionHeader(
        title: String,
        count: Int,
        isExpanded: Bool,
        isToggleable: Bool,
        onToggle: (() -> Void)? = nil
    ) -> some View {
        let progressLine = "\(completedCount(in: title == "Warmup" ? warmupSets : workingSets))/\(count)"

        HStack(alignment: .center) {
            Text(title)
                .font(.headline.weight(.semibold))
                .foregroundStyle(LiftTheme.textPrimary)

            Spacer()

            if isToggleable, let onToggle {
                Button(action: onToggle) {
                    HStack(spacing: 6) {
                        Text(progressLine)
                            .font(.subheadline.weight(.semibold))
                            .monospacedDigit()
                            .foregroundStyle(LiftTheme.accent)
                        Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                            .font(.caption.weight(.bold))
                            .foregroundStyle(LiftTheme.accent)
                    }
                }
                .buttonStyle(.plain)
                .accessibilityLabel("\(title) — \(progressLine) complete. \(isExpanded ? "Collapse" : "Expand")")
            } else {
                Text(progressLine)
                    .font(.subheadline.weight(.semibold))
                    .monospacedDigit()
                    .foregroundStyle(LiftTheme.accent)
                    .accessibilityLabel("\(title) — \(progressLine) complete")
            }
        }
    }
}

#Preview {
    let viewModel = PreviewSupport.todayViewModel()
    let draftPlan = PreviewSupport.draftPlan()

    ScrollView {
        TodayExerciseCard(
            exerciseLog: draftPlan.exerciseLogs[0],
            weightLoading: viewModel.weightLoading,
            onTapSet: { _ in },
            onEditWorkingWeight: { _ in },
            onEditSetWeight: { _, _ in },
            onEditSetReps: { _, _ in },
            onDeleteSet: { _ in },
            onAddWarmup: {}
        )
        .padding()
    }
    .background(LiftTheme.canvas)
}
