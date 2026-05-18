import SwiftData
import SwiftUI

struct SettingsView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.healthKit) private var healthKit
    @State private var viewModel = SettingsViewModel()
    @State private var showResetAllConfirm = false
    @State private var resetAllError: String?
    @State private var healthKitStatus: HealthKitAuthorizationStatus = .notDetermined
    @State private var isRequestingHealthAccess = false

    var body: some View {
        NavigationStack {
            List {
                if viewModel.hasActiveDraft {
                    Section {
                        Label {
                            VStack(alignment: .leading, spacing: 4) {
                                Text("Workout in progress")
                                    .font(.subheadline.weight(.semibold))
                                Text("Finish or discard your active workout before changing weights, deload, or reset.")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        } icon: {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundStyle(.orange)
                        }
                    }
                }

                Section("Equipment") {
                    NavigationLink {
                        EquipmentSettingsView(viewModel: viewModel)
                    } label: {
                        if let user = viewModel.user {
                            HStack {
                                Label("Bar & plates", systemImage: "scalemass")
                                Spacer()
                                Text("\(formatted(user.barWeightKg)) kg bar")
                                    .foregroundStyle(.secondary)
                                    .font(.subheadline)
                            }
                        } else {
                            Label("Bar & plates", systemImage: "scalemass")
                        }
                    }
                }

                Section("Exercises") {
                    if viewModel.progressions.isEmpty {
                        Text("No exercises yet").foregroundStyle(.secondary)
                    } else {
                        ForEach(viewModel.progressions, id: \.persistentModelID) { progression in
                            NavigationLink {
                                ExerciseSettingsView(viewModel: viewModel, progression: progression)
                            } label: {
                                ExerciseSettingsRow(progression: progression)
                            }
                        }
                    }
                }

                Section("Danger zone") {
                    Button(role: .destructive) {
                        showResetAllConfirm = true
                    } label: {
                        Label("Reset all data", systemImage: "trash")
                    }
                }

                if healthKit.isAvailable {
                    Section("Apple Health") {
                        HStack {
                            Label("Workouts", systemImage: "heart.fill")
                            Spacer()
                            Text(healthStatusLabel)
                                .foregroundStyle(.secondary)
                                .font(.subheadline)
                        }

                        if healthKitStatus == .notDetermined {
                            Button {
                                Task { await requestHealthAccess() }
                            } label: {
                                Label("Allow Lift to save workouts", systemImage: "checkmark.shield")
                            }
                            .disabled(isRequestingHealthAccess)
                        } else if healthKitStatus == .denied {
                            Text("Open the Health app to grant access to write workouts.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                Section("About") {
                    HStack {
                        Text("Version")
                        Spacer()
                        Text(Bundle.main.appVersionString).foregroundStyle(.secondary)
                    }
                }
            }
            .navigationTitle("Settings")
            .task {
                viewModel.setModelContext(modelContext)
                viewModel.refresh()
                healthKitStatus = healthKit.authorizationStatus()
            }
            .confirmationDialog(
                "Reset all data?",
                isPresented: $showResetAllConfirm,
                titleVisibility: .visible
            ) {
                Button("Reset everything", role: .destructive) {
                    do {
                        try viewModel.resetAllData()
                    } catch {
                        resetAllError = "Could not reset: \(error.localizedDescription)"
                    }
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("This deletes all sessions, history, progressions, and equipment, then re-seeds the default program. This cannot be undone.\(viewModel.hasActiveDraft ? " Your in-progress workout will also be discarded." : "")")
            }
            .alert("Reset failed", isPresented: Binding(get: { resetAllError != nil }, set: { if !$0 { resetAllError = nil } })) {
                Button("OK") { resetAllError = nil }
            } message: {
                Text(resetAllError ?? "")
            }
        }
    }

    private func formatted(_ kg: Double) -> String {
        kg.formatted(.number.precision(.fractionLength(0 ... 2)))
    }

    private var healthStatusLabel: String {
        switch healthKitStatus {
        case .sharingAuthorized: return "Saving workouts"
        case .denied: return "Access denied"
        case .notDetermined: return "Not requested"
        case .notAvailable: return "Not available"
        }
    }

    private func requestHealthAccess() async {
        isRequestingHealthAccess = true
        defer { isRequestingHealthAccess = false }
        do {
            healthKitStatus = try await healthKit.requestAuthorizationIfNeeded()
        } catch {
            healthKitStatus = healthKit.authorizationStatus()
        }
    }
}

private struct ExerciseSettingsRow: View {
    let progression: ExerciseProgression

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(progression.exercise?.name ?? "Exercise")
                    .font(.body.weight(.medium))
                Text("\(progression.workingSets)×\(progression.workingReps) · \(formatted(progression.currentWeightKg)) kg")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if progression.stalledCount > 0 {
                Text("STALLED ×\(progression.stalledCount)")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(.orange)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.orange.opacity(0.15), in: Capsule())
                    .accessibilityLabel("Stalled \(progression.stalledCount) sessions")
            }
        }
    }

    private func formatted(_ kg: Double) -> String {
        kg.formatted(.number.precision(.fractionLength(0 ... 2)))
    }
}

private extension Bundle {
    var appVersionString: String {
        let short = (infoDictionary?["CFBundleShortVersionString"] as? String) ?? "0"
        let build = (infoDictionary?["CFBundleVersion"] as? String) ?? "0"
        return "\(short) (\(build))"
    }
}

#Preview {
    SettingsView()
        .modelContainer(PreviewSupport.container)
}
