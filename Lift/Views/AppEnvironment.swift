import SwiftUI
import UIKit

struct HapticsClient: Sendable {
    var workingSetCompleted: @MainActor @Sendable () -> Void
    var restCompleted: @MainActor @Sendable () -> Void
    var workoutFinished: @MainActor @Sendable () -> Void
    var deloadApplied: @MainActor @Sendable () -> Void

    static let live = HapticsClient(
        workingSetCompleted: {
            let generator = UIImpactFeedbackGenerator(style: .medium)
            generator.prepare()
            generator.impactOccurred()
        },
        restCompleted: {
            let generator = UINotificationFeedbackGenerator()
            generator.prepare()
            generator.notificationOccurred(.success)
        },
        workoutFinished: {
            let generator = UINotificationFeedbackGenerator()
            generator.prepare()
            generator.notificationOccurred(.success)
        },
        deloadApplied: {
            let generator = UINotificationFeedbackGenerator()
            generator.prepare()
            generator.notificationOccurred(.warning)
        }
    )

    static let disabled = HapticsClient(
        workingSetCompleted: {},
        restCompleted: {},
        workoutFinished: {},
        deloadApplied: {}
    )
}

private struct HapticsKey: EnvironmentKey {
    static let defaultValue = HapticsClient.disabled
}

private struct RestTimerKey: EnvironmentKey {
    static let defaultValue: RestTimerService? = nil
}

private struct HealthKitKey: EnvironmentKey {
    static let defaultValue: any HealthKitWriting = HealthKitStub(status: .notDetermined)
}

extension EnvironmentValues {
    var haptics: HapticsClient {
        get { self[HapticsKey.self] }
        set { self[HapticsKey.self] = newValue }
    }

    var restTimer: RestTimerService? {
        get { self[RestTimerKey.self] }
        set { self[RestTimerKey.self] = newValue }
    }

    var healthKit: any HealthKitWriting {
        get { self[HealthKitKey.self] }
        set { self[HealthKitKey.self] = newValue }
    }
}
