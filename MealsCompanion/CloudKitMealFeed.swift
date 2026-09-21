import CloudKit
import Foundation
import UIKit
import UserNotifications
import WidgetKit

enum WidgetReloader {
    static func reload() {
        WidgetCenter.shared.reloadTimelines(ofKind: WidgetKind.latestMeal)
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
    var latestPhoto: UIImage?
    var lastError: String?
    var isRefreshing = false
    var iCloudStatus: CKAccountStatus?
    var userVisibleNotificationsEnabled: Bool

    private let client = CloudKitMealClient()
    private var lastNotifiedMealID: String?

    private init() {
        pairing = PairingStore.load()
        meals = LatestMealStore.loadMeals()
        latestPhoto = LatestMealStore.loadLatestImage()
        userVisibleNotificationsEnabled = NotificationPreferences.userVisibleEnabled
    }

    var isUsingPlaceholderTeam: Bool {
        RuntimeConfig.cloudKitContainerIdentifier.contains("TEAMID")
            || RuntimeConfig.appGroupIdentifier.contains("TEAMID")
    }

    func bootstrap() async {
        persistSnapshot()
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

    func refresh() async {
        guard pairing.isPaired else {
            persistSnapshot()
            WidgetReloader.reload()
            return
        }
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
            let fetched = try await client.fetchMeals(ownerName: pairing.ownerName)
            let previousID = meals.first?.id
            meals = fetched.meals
            pairing.ownerName = fetched.ownerName ?? pairing.ownerName
            pairing.zoneName = fetched.zoneName ?? pairing.zoneName
            if let photo = fetched.latestPhotoData {
                latestPhoto = UIImage(data: photo)
            } else {
                latestPhoto = LatestMealStore.loadLatestImage()
            }
            lastError = nil
            persistSnapshot(latestPhotoData: fetched.latestPhotoData)
            try? await client.ensureSilentSubscription(zoneName: pairing.zoneName)
            WidgetReloader.reload()
            notifyIfNeeded(previousMealID: previousID)
        } catch {
            lastError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
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

    func handleSilentPush() async {
        await refresh()
    }

    func unpair() {
        pairing = .unpaired
        meals = []
        latestPhoto = nil
        lastError = nil
        lastNotifiedMealID = nil
        LatestMealStore.clear()
        WidgetReloader.reload()
        Task { try? await client.dropSubscriptions() }
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
        if pairing.isPaired {
            try? await client.ensureSilentSubscription(zoneName: pairing.zoneName)
        }
    }

#if DEBUG
    func loadSampleMeal() {
        LatestMealStore.saveSampleMealForPreviews()
        pairing = PairingStore.load()
        meals = LatestMealStore.loadMeals()
        latestPhoto = LatestMealStore.loadLatestImage()
        WidgetReloader.reload()
    }
#endif

    private func persistSnapshot(latestPhotoData: Data? = nil) {
        let photo = latestPhotoData ?? latestPhoto.flatMap { $0.jpegData(compressionQuality: 0.82) }
        LatestMealStore.save(meals: meals, latestPhoto: photo, pairing: pairing)
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

struct FetchedMealFeed: Sendable {
    var meals: [Meal]
    var ownerName: String?
    var zoneName: String?
    var latestPhotoData: Data?
}

struct CloudKitMealClient: Sendable {
    private var container: CKContainer {
        CKContainer(identifier: RuntimeConfig.cloudKitContainerIdentifier)
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
            try await metadata.container.accept(metadata)
        } catch {
            throw MealFeedError.acceptFailed(error.localizedDescription)
        }
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

    func fetchMeals(ownerName: String?) async throws -> FetchedMealFeed {
        let database = container.sharedCloudDatabase
        let zones: [CKRecordZone]
        do {
            zones = try await database.allRecordZones()
        } catch {
            throw MealFeedError.fetchFailed(error.localizedDescription)
        }

        var records: [CKRecord] = []
        var feedOwner = ownerName
        var zoneName: String?

        for zone in zones {
            zoneName = zone.zoneID.zoneName
            let mealQuery = CKQuery(
                recordType: MealCloudKit.mealRecordType,
                predicate: NSPredicate(value: true)
            )
            do {
                let (matched, _) = try await database.records(
                    matching: mealQuery,
                    inZoneWith: zone.zoneID,
                    desiredKeys: [
                        MealCloudKit.titleKey,
                        MealCloudKit.photographedAtKey,
                        MealCloudKit.photoKey,
                        MealCloudKit.ownerDisplayNameKey
                    ],
                    resultsLimit: 30
                )
                for (_, result) in matched {
                    if case .success(let record) = result {
                        records.append(record)
                    }
                }
            } catch let error as CKError where error.code == .unknownItem {
                continue
            } catch {
                throw MealFeedError.fetchFailed(error.localizedDescription)
            }

            let feedQuery = CKQuery(
                recordType: MealCloudKit.feedRecordType,
                predicate: NSPredicate(value: true)
            )
            if let (matched, _) = try? await database.records(
                matching: feedQuery,
                inZoneWith: zone.zoneID,
                desiredKeys: [MealCloudKit.ownerDisplayNameKey],
                resultsLimit: 1
            ) {
                for (_, result) in matched {
                    if case .success(let record) = result,
                       let name = record[MealCloudKit.ownerDisplayNameKey] as? String {
                        feedOwner = name
                    }
                }
            }
        }

        records.sort { lhs, rhs in
            date(from: lhs) > date(from: rhs)
        }

        var meals: [Meal] = []
        var latestPhoto: Data?
        for (index, record) in records.enumerated() {
            let title = (record[MealCloudKit.titleKey] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
            var meal = Meal(
                id: record.recordID.recordName,
                title: (title?.isEmpty == false ? title : nil) ?? "Meal",
                photographedAt: date(from: record),
                ownerName: (record[MealCloudKit.ownerDisplayNameKey] as? String) ?? feedOwner
            )
            if let asset = record[MealCloudKit.photoKey] as? CKAsset,
               let fileURL = asset.fileURL,
               let data = try? Data(contentsOf: fileURL) {
                meal.photoFileName = LatestMealStore.savePhoto(data, mealID: meal.id)
                if index == 0 { latestPhoto = data }
            }
            meals.append(meal)
        }

        return FetchedMealFeed(
            meals: meals,
            ownerName: feedOwner,
            zoneName: zoneName,
            latestPhotoData: latestPhoto
        )
    }

    func ensureSilentSubscription(zoneName: String?) async throws {
        let database = container.sharedCloudDatabase
        let zones = try await database.allRecordZones()
        let target = zones.filter { zone in
            guard let zoneName else { return true }
            return zone.zoneID.zoneName == zoneName
        }
        for zone in target {
            let subscriptionID = "meals-silent-\(zone.zoneID.zoneName)"
            let subscription = CKRecordZoneSubscription(zoneID: zone.zoneID, subscriptionID: subscriptionID)
            let info = CKSubscription.NotificationInfo()
            info.shouldSendContentAvailable = true
            if NotificationPreferences.userVisibleEnabled {
                info.alertBody = "New meal photo"
            } else {
                info.shouldSendContentAvailable = true
                info.alertBody = nil
                info.soundName = nil
                info.shouldBadge = false
            }
            subscription.notificationInfo = info
            _ = try? await database.save(subscription)
        }
    }

    func dropSubscriptions() async throws {
        let database = container.sharedCloudDatabase
        let subscriptions = (try? await database.allSubscriptions()) ?? []
        for subscription in subscriptions {
            _ = try? await database.deleteSubscription(withID: subscription.subscriptionID)
        }
    }

    private func date(from record: CKRecord) -> Date {
        record[MealCloudKit.photographedAtKey] as? Date ?? record.creationDate ?? Date()
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
