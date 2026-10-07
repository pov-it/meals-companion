import CloudKit
import Foundation
import UIKit
import UserNotifications
import WidgetKit

enum WidgetReloader {
    static func reload() {
        WidgetCenter.shared.reloadAllTimelines()
    }
}

enum MealFeedError: LocalizedError {
    case placeholderTeam
    case iCloudUnavailable(CKAccountStatus)
    case invalidShareLink
    case acceptFailed(String)
    case fetchFailed(String)

    var errorDescription: String? {
        switch self {
        case .placeholderTeam:
            return "Set DEVELOPMENT_TEAM in Config/Team.xcconfig before CloudKit pairing can work."
        case .iCloudUnavailable(let status):
            switch status {
            case .noAccount:
                return "Sign in to iCloud on this iPhone to accept the meal share."
            case .restricted, .temporarilyUnavailable:
                return "iCloud is unavailable on this device right now."
            case .couldNotDetermine:
                return "Could not determine iCloud status."
            case .available:
                return "iCloud is available, but the share could not be opened."
            @unknown default:
                return "iCloud is not available."
            }
        case .invalidShareLink:
            return "That does not look like an iCloud share link."
        case .acceptFailed(let message):
            return "Could not accept the share. \(message)"
        case .fetchFailed(let message):
            return "Could not load meals. \(message)"
        }
    }
}

@MainActor
@Observable
final class MealFeedController {
    static let shared = MealFeedController()

    var pairing: PairingState
    var meals: [Meal]
    var lastError: String?
    var isRefreshing = false
    var iCloudStatus: CKAccountStatus?
    var userVisibleNotificationsEnabled: Bool

    private let client = CloudKitMealClient()
    private var lastNotifiedMealID: String?
    private var inFlightRefresh: Task<UIBackgroundFetchResult, Never>?

    private init() {
        pairing = PairingStore.load()
        meals = LatestMealStore.loadMeals()
        userVisibleNotificationsEnabled = NotificationPreferences.userVisibleEnabled
    }

    var isUsingPlaceholderTeam: Bool {
        RuntimeConfig.cloudKitContainerIdentifier.contains("TEAMID")
            || RuntimeConfig.appGroupIdentifier.contains("TEAMID")
    }

    func bootstrap() async {
        WidgetReloader.reload()
        await refreshAccountStatus()
        UIApplication.shared.registerForRemoteNotifications()
        if pairing.isPaired {
            await refresh()
        }
    }

    func refreshAccountStatus() async {
        do {
            iCloudStatus = try await client.accountStatus()
        } catch {
            iCloudStatus = .couldNotDetermine
        }
    }

    /// Concurrent callers (scene activation, silent push, background task) share one fetch.
    @discardableResult
    func refresh() async -> UIBackgroundFetchResult {
        if let inFlightRefresh {
            return await inFlightRefresh.value
        }
        let task = Task { await performRefresh() }
        inFlightRefresh = task
        let result = await task.value
        inFlightRefresh = nil
        return result
    }

    private func performRefresh() async -> UIBackgroundFetchResult {
        guard pairing.isPaired else {
            persistSnapshot()
            WidgetReloader.reload()
            return .noData
        }
        guard !isUsingPlaceholderTeam else {
            lastError = MealFeedError.placeholderTeam.localizedDescription
            return .failed
        }
        isRefreshing = true
        defer { isRefreshing = false }
        do {
            await refreshAccountStatus()
            if let iCloudStatus, iCloudStatus != .available {
                throw MealFeedError.iCloudUnavailable(iCloudStatus)
            }
            let previous = LatestMealStore.snapshot().meal
            let fetched: FetchedMealFeed
            do {
                fetched = try await client.fetcher.fetchFeed(ownerName: pairing.ownerName, photoDownloadLimit: 30)
            } catch {
                MealsLog.cloudKit.error("Meal fetch failed: \(error.localizedDescription, privacy: .public)")
                throw MealFeedError.fetchFailed(error.localizedDescription)
            }
            let previousNewestID = meals.first?.id
            meals = fetched.meals
            pairing.ownerName = fetched.ownerName ?? pairing.ownerName
            pairing.zoneName = fetched.zoneName ?? pairing.zoneName
            lastError = nil
            persistSnapshot()
            LatestMealStore.prunePhotos(keeping: Set(meals.compactMap(\.photoFileName)))
            await client.ensureDatabaseSubscription()
            WidgetReloader.reload()
            notifyIfNeeded(previousMealID: previousNewestID)
            let changed = fetched.latestPhotographedMeal != previous || fetched.meals.first?.id != previousNewestID
            return changed ? .newData : .noData
        } catch {
            lastError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            return .failed
        }
    }

    func acceptShare(from url: URL) async {
        lastError = nil
        guard !isUsingPlaceholderTeam else {
            lastError = MealFeedError.placeholderTeam.localizedDescription
            return
        }
        isRefreshing = true
        defer { isRefreshing = false }
        do {
            await refreshAccountStatus()
            if let iCloudStatus, iCloudStatus != .available {
                throw MealFeedError.iCloudUnavailable(iCloudStatus)
            }
            let accepted = try await client.acceptShare(url: url)
            pairing = accepted
            persistSnapshot()
            await refresh()
            if meals.isEmpty {
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                await refresh()
            }
        } catch {
            lastError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    func acceptCloudKitShare(_ metadata: CKShare.Metadata) async {
        lastError = nil
        isRefreshing = true
        defer { isRefreshing = false }
        do {
            let accepted = try await client.accept(metadata: metadata)
            pairing = accepted
            persistSnapshot()
            await refresh()
            if meals.isEmpty {
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                await refresh()
            }
        } catch {
            lastError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    func handleSilentPush() async -> UIBackgroundFetchResult {
        await refresh()
    }

    func unpair() {
        pairing = .unpaired
        meals = []
        lastError = nil
        lastNotifiedMealID = nil
        LatestMealStore.clear()
        WidgetReloader.reload()
        Task { await client.dropSubscriptions() }
    }

    func setUserVisibleNotifications(_ enabled: Bool) async {
        if enabled {
            let center = UNUserNotificationCenter.current()
            let granted = try? await center.requestAuthorization(options: [.alert, .sound])
            userVisibleNotificationsEnabled = granted == true
            NotificationPreferences.userVisibleEnabled = userVisibleNotificationsEnabled
            if granted != true {
                lastError = "Notifications were not allowed. The widget still updates without them."
            }
        } else {
            userVisibleNotificationsEnabled = false
            NotificationPreferences.userVisibleEnabled = false
        }
    }

#if DEBUG
    func loadSampleMeal() {
        LatestMealStore.saveSampleMealForPreviews()
        pairing = PairingStore.load()
        meals = LatestMealStore.loadMeals()
        WidgetReloader.reload()
    }
#endif

    private func persistSnapshot() {
        LatestMealStore.save(meals: meals, pairing: pairing)
    }

    private func notifyIfNeeded(previousMealID: String?) {
        guard NotificationPreferences.userVisibleEnabled else { return }
        guard let meal = meals.first, meal.id != previousMealID, meal.id != lastNotifiedMealID else { return }
        lastNotifiedMealID = meal.id
        let content = UNMutableNotificationContent()
        content.title = meal.ownerName.map { "\($0)’s meal" } ?? "New meal"
        content.body = "\(meal.title) · \(RelativeTimestamp.widgetLabel(from: meal.photographedAt))"
        content.sound = nil
        let request = UNNotificationRequest(identifier: meal.id, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }
}

struct CloudKitMealClient: Sendable {
    /// The shared database only supports CKDatabaseSubscription; zone and query
    /// subscriptions are rejected there.
    static let subscriptionID = "meals-shared-database"
    private static let legacySubscriptionPrefix = "meals-silent-"
    private static let subscriptionCheckedKey = "cloudkit.subscription.checkedAt"
    private static let subscriptionRecheckInterval: TimeInterval = 12 * 3600

    let fetcher = MealCloudKitFetcher()

    private var container: CKContainer {
        fetcher.container
    }

    func accountStatus() async throws -> CKAccountStatus {
        try await container.accountStatus()
    }

    func acceptShare(url: URL) async throws -> PairingState {
        guard isLikelyShareURL(url) else { throw MealFeedError.invalidShareLink }
        let metadata = try await fetchShareMetadata(for: url)
        return try await accept(metadata: metadata, shareURL: url)
    }

    func accept(metadata: CKShare.Metadata, shareURL: URL? = nil) async throws -> PairingState {
        do {
            let shareContainer = CKContainer(identifier: metadata.containerIdentifier)
            try await shareContainer.accept(metadata)
        } catch {
            throw MealFeedError.acceptFailed(error.localizedDescription)
        }
        UserDefaults.standard.removeObject(forKey: Self.subscriptionCheckedKey)
        let share = metadata.share
        let owner: String? = {
            guard let components = metadata.ownerIdentity.nameComponents else { return nil }
            let formatter = PersonNameComponentsFormatter()
            formatter.style = .medium
            let name = formatter.string(from: components).trimmingCharacters(in: .whitespacesAndNewlines)
            return name.isEmpty ? nil : name
        }()
        return PairingState(
            isPaired: true,
            ownerName: owner,
            shareURLString: shareURL?.absoluteString ?? share.url?.absoluteString,
            acceptedAt: Date(),
            zoneName: share.recordID.zoneID.zoneName,
            rootRecordName: metadata.hierarchicalRootRecordID?.recordName ?? share.recordID.recordName
        )
    }

    /// Silent (content-available only) push for any change in the shared database.
    /// User-visible alerts are posted locally after a refresh, so the push itself stays silent.
    func ensureDatabaseSubscription() async {
        let defaults = UserDefaults.standard
        if let checked = defaults.object(forKey: Self.subscriptionCheckedKey) as? Date,
           Date().timeIntervalSince(checked) < Self.subscriptionRecheckInterval {
            return
        }
        let database = container.sharedCloudDatabase
        do {
            let existing = try await database.allSubscriptions()
            let legacy = existing.map(\.subscriptionID).filter { $0.hasPrefix(Self.legacySubscriptionPrefix) }
            if !legacy.isEmpty {
                let (_, deleted) = try await database.modifySubscriptions(saving: [], deleting: legacy)
                for (id, result) in deleted {
                    if case .failure(let error) = result {
                        MealsLog.cloudKit.error("Could not delete subscription \(id, privacy: .public): \(error.localizedDescription, privacy: .public)")
                    }
                }
            }
            if !existing.contains(where: { $0.subscriptionID == Self.subscriptionID }) {
                let subscription = CKDatabaseSubscription(subscriptionID: Self.subscriptionID)
                let info = CKSubscription.NotificationInfo()
                info.shouldSendContentAvailable = true
                subscription.notificationInfo = info
                _ = try await database.save(subscription)
                MealsLog.cloudKit.info("Saved shared-database subscription")
            }
            defaults.set(Date(), forKey: Self.subscriptionCheckedKey)
        } catch {
            MealsLog.cloudKit.error("Shared-database subscription failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    func dropSubscriptions() async {
        UserDefaults.standard.removeObject(forKey: Self.subscriptionCheckedKey)
        let database = container.sharedCloudDatabase
        do {
            let ids = try await database.allSubscriptions().map(\.subscriptionID)
            guard !ids.isEmpty else { return }
            let (_, deleted) = try await database.modifySubscriptions(saving: [], deleting: ids)
            for (id, result) in deleted {
                if case .failure(let error) = result {
                    MealsLog.cloudKit.error("Could not delete subscription \(id, privacy: .public): \(error.localizedDescription, privacy: .public)")
                }
            }
        } catch {
            MealsLog.cloudKit.error("Could not list subscriptions: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func isLikelyShareURL(_ url: URL) -> Bool {
        let text = url.absoluteString.lowercased()
        return text.contains("icloud.com/share")
            || text.contains("cloudkit")
            || url.scheme?.lowercased() == "cloudkit-share"
    }

    private func fetchShareMetadata(for url: URL) async throws -> CKShare.Metadata {
        try await withCheckedThrowingContinuation { continuation in
            container.fetchShareMetadata(with: url) { metadata, error in
                if let metadata {
                    continuation.resume(returning: metadata)
                } else {
                    continuation.resume(
                        throwing: MealFeedError.acceptFailed(error?.localizedDescription ?? "Invalid share link.")
                    )
                }
            }
        }
    }
}
