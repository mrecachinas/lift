import SwiftData
import SwiftUI
@preconcurrency import UserNotifications

@main
struct LiftApp: App {
    @State private var persistenceService = PersistenceService()
    @State private var restTimer = RestTimerService()
    private let notificationDelegate = LiftNotificationDelegate()
    #if canImport(HealthKit)
    private let healthKit: any HealthKitWriting = LiveHealthKitService()
    #else
    private let healthKit: any HealthKitWriting = HealthKitStub(isAvailable: false, status: .notAvailable)
    #endif

    init() {
        UNUserNotificationCenter.current().delegate = notificationDelegate
    }

    var body: some Scene {
        WindowGroup {
            AppRootView(persistenceService: persistenceService)
                .modelContainer(persistenceService.container)
                .environment(\.restTimer, restTimer)
                .environment(\.haptics, .live)
                .environment(\.healthKit, healthKit)
                .liftThemedScene()
        }
    }
}

private struct AppRootView: View {
    @Bindable var persistenceService: PersistenceService

    var body: some View {
        Group {
            if persistenceService.isBootstrapped {
                if persistenceService.shouldShowOnboarding {
                    FirstRunWizard(persistenceService: persistenceService)
                } else {
                    RootTabView()
                }
            } else {
                ProgressView()
            }
        }
        .task {
            await persistenceService.bootstrap()
        }
    }
}

final class LiftNotificationDelegate: NSObject, UNUserNotificationCenterDelegate {
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        if notification.request.identifier.hasPrefix("rest-") {
            completionHandler([])
        } else {
            completionHandler([.banner, .sound])
        }
    }
}
