import Foundation
#if canImport(HealthKit)
import HealthKit
#endif

enum HealthKitAuthorizationStatus: Sendable, Equatable {
    case notDetermined
    case denied
    case sharingAuthorized
    case notAvailable
}

/// Saves workouts to Apple Health. Live implementation is `LiveHealthKitService`; tests use
/// `HealthKitStub` to record calls without linking against HealthKit.
protocol HealthKitWriting: Sendable {
    /// Returns whether HealthKit is available on this device.
    var isAvailable: Bool { get }

    /// Returns the current "share" authorization status for workout writes. The user has to grant
    /// explicit permission before we can save anything; HealthKit deliberately reports
    /// `notDetermined` even after a denial, so a save failure is the only authoritative signal
    /// that we lack permission.
    func authorizationStatus() -> HealthKitAuthorizationStatus

    /// Prompts the user for HealthKit write permission if they haven't already responded.
    /// Returns the post-prompt status. No-op on devices without HealthKit.
    @discardableResult
    func requestAuthorizationIfNeeded() async throws -> HealthKitAuthorizationStatus

    /// Saves a workout to Apple Health spanning the given window. Throws if not authorized.
    func saveWorkout(start: Date, end: Date) async throws
}

#if canImport(HealthKit)

@MainActor
final class LiveHealthKitService: HealthKitWriting {
    private let store: HKHealthStore?

    init() {
        self.store = HKHealthStore.isHealthDataAvailable() ? HKHealthStore() : nil
    }

    nonisolated var isAvailable: Bool {
        HKHealthStore.isHealthDataAvailable()
    }

    nonisolated func authorizationStatus() -> HealthKitAuthorizationStatus {
        guard HKHealthStore.isHealthDataAvailable() else { return .notAvailable }
        let store = HKHealthStore()
        let status = store.authorizationStatus(for: .workoutType())
        switch status {
        case .notDetermined: return .notDetermined
        case .sharingAuthorized: return .sharingAuthorized
        case .sharingDenied: return .denied
        @unknown default: return .notDetermined
        }
    }

    func requestAuthorizationIfNeeded() async throws -> HealthKitAuthorizationStatus {
        guard let store else { return .notAvailable }
        let workoutType = HKObjectType.workoutType()
        try await store.requestAuthorization(toShare: [workoutType], read: [workoutType])
        return authorizationStatus()
    }

    func saveWorkout(start: Date, end: Date) async throws {
        guard let store else { return }
        let builder = HKWorkoutBuilder(
            healthStore: store,
            configuration: workoutConfiguration(),
            device: .local()
        )
        try await builder.beginCollection(at: start)
        try await builder.endCollection(at: end)
        try await builder.finishWorkout()
    }

    private func workoutConfiguration() -> HKWorkoutConfiguration {
        let config = HKWorkoutConfiguration()
        config.activityType = .functionalStrengthTraining
        config.locationType = .indoor
        return config
    }
}

#endif

/// In-memory stub used by previews and tests. Records every save with the timestamps it received.
final class HealthKitStub: HealthKitWriting, @unchecked Sendable {
    struct SavedWorkout: Sendable, Equatable {
        let start: Date
        let end: Date
    }

    private let lock = NSLock()
    private var _savedWorkouts: [SavedWorkout] = []
    private var _authorizationRequested = false
    private var _status: HealthKitAuthorizationStatus
    private let _isAvailable: Bool
    private let saveError: Error?

    init(
        isAvailable: Bool = true,
        status: HealthKitAuthorizationStatus = .sharingAuthorized,
        saveError: Error? = nil
    ) {
        self._isAvailable = isAvailable
        self._status = status
        self.saveError = saveError
    }

    var isAvailable: Bool { _isAvailable }

    func authorizationStatus() -> HealthKitAuthorizationStatus {
        lock.withLock { _status }
    }

    func requestAuthorizationIfNeeded() async throws -> HealthKitAuthorizationStatus {
        lock.withLock {
            _authorizationRequested = true
            if _status == .notDetermined {
                _status = .sharingAuthorized
            }
            return _status
        }
    }

    func saveWorkout(start: Date, end: Date) async throws {
        if let saveError { throw saveError }
        lock.withLock {
            _savedWorkouts.append(SavedWorkout(start: start, end: end))
        }
    }

    var savedWorkouts: [SavedWorkout] {
        lock.withLock { _savedWorkouts }
    }

    var authorizationRequested: Bool {
        lock.withLock { _authorizationRequested }
    }
}
