import CloudKit
import SwiftUI
import UIKit

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
                    if phase == .active {
                        Task { await MealFeedController.shared.refresh() }
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

final class MealsAppDelegate: NSObject, UIApplicationDelegate {
    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
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
        Task { @MainActor in
            await MealFeedController.shared.handleSilentPush()
            completionHandler(isCloudKit ? .newData : .noData)
        }
    }
}
