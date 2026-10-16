import BackgroundTasks
import CloudKit
import SwiftUI
import UIKit
import WidgetKit

@main
struct MealsCompanionApp: App {
    @UIApplicationDelegateAdaptor(MealsAppDelegate.self) private var appDelegate
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(MealFeedController.shared)
                .task {
                    await MealFeedController.shared.bootstrap()
                }
                .onChange(of: scenePhase) { _, phase in
                    switch phase {
                    case .active:
                        Task { await MealFeedController.shared.refresh() }
                    case .background:
                        BackgroundRefresh.schedule()
                    default:
                        break
                    }
                }
                .onOpenURL { url in
                    Task { await MealFeedController.shared.acceptShare(from: url) }
                }
                .onContinueUserActivity(NSUserActivityTypeBrowsingWeb) { activity in
                    if let url = activity.webpageURL {
                        Task { await MealFeedController.shared.acceptShare(from: url) }
                    }
                }
        }
    }
}

/// Periodic BGAppRefreshTask so the App Group snapshot (and the widget) catches up
/// even when no silent push arrives. iOS decides the real cadence; the interval is a floor.
enum BackgroundRefresh {
    /// Must match BGTaskSchedulerPermittedIdentifiers in Info.plist.
    static var taskIdentifier: String {
        (Bundle.main.bundleIdentifier ?? "meals") + ".refresh"
    }

    static let minimumInterval: TimeInterval = 4 * 3600

    static func register() {
        let identifier = taskIdentifier
        let registered = BGTaskScheduler.shared.register(forTaskWithIdentifier: identifier, using: nil) { task in
            guard let task = task as? BGAppRefreshTask else {
                task.setTaskCompleted(success: false)
                return
            }
            handle(task)
        }
        if !registered {
            MealsLog.refresh.error("Could not register \(identifier, privacy: .public)")
        }
    }

    static func schedule() {
        let request = BGAppRefreshTaskRequest(identifier: taskIdentifier)
        request.earliestBeginDate = Date(timeIntervalSinceNow: minimumInterval)
        do {
            try BGTaskScheduler.shared.submit(request)
        } catch {
            MealsLog.refresh.error("Could not schedule app refresh: \(error.localizedDescription, privacy: .public)")
        }
    }

    private static func handle(_ task: BGAppRefreshTask) {
        schedule()
        let work = Task { @MainActor in
            let result = await MealFeedController.shared.refresh()
            WidgetCenter.shared.reloadAllTimelines()
            MealsLog.refresh.info("Background refresh finished: \(result.rawValue, privacy: .public)")
            task.setTaskCompleted(success: result != .failed && !Task.isCancelled)
        }
        task.expirationHandler = {
            work.cancel()
        }
    }
}

final class MealsAppDelegate: NSObject, UIApplicationDelegate {
    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        BackgroundRefresh.register()
        BackgroundRefresh.schedule()
        application.registerForRemoteNotifications()
        return true
    }

    func application(
        _ application: UIApplication,
        userDidAcceptCloudKitShareWith cloudKitShareMetadata: CKShare.Metadata
    ) {
        Task { @MainActor in
            await MealFeedController.shared.acceptCloudKitShare(cloudKitShareMetadata)
        }
    }

    func application(
        _ application: UIApplication,
        didReceiveRemoteNotification userInfo: [AnyHashable: Any],
        fetchCompletionHandler completionHandler: @escaping (UIBackgroundFetchResult) -> Void
    ) {
        let isCloudKit = (userInfo as? [String: NSObject]).flatMap {
            CKNotification(fromRemoteNotificationDictionary: $0)
        } != nil
        guard isCloudKit else {
            completionHandler(.noData)
            return
        }
        Task { @MainActor in
            let result = await MealFeedController.shared.handleSilentPush()
            completionHandler(result)
        }
    }

    func application(
        _ application: UIApplication,
        didFailToRegisterForRemoteNotificationsWithError error: Error
    ) {
        MealsLog.cloudKit.error("Remote notification registration failed: \(error.localizedDescription, privacy: .public)")
    }
}
