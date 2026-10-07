import CloudKit
import Foundation
import os

public enum MealsLog {
    public static let cloudKit = Logger(subsystem: Bundle.main.bundleIdentifier ?? "meals", category: "CloudKit")
    public static let refresh = Logger(subsystem: Bundle.main.bundleIdentifier ?? "meals", category: "Refresh")
}

public struct FetchedMealFeed: Sendable {
    /// Every meal in the share, newest first. `photoFileName` is set for meals whose photo is cached locally.
    public var meals: [Meal]
    public var ownerName: String?
    public var zoneName: String?
    public var latestPhotographedMeal: Meal?
    public var latestPhotoData: Data?
}

/// Reads the meal feed from the CloudKit shared database. Used by the app and,
/// when it carries the iCloud entitlement, by the widget extension.
public struct MealCloudKitFetcher: Sendable {
    public let containerIdentifier: String

    public init(containerIdentifier: String = RuntimeConfig.cloudKitContainerIdentifier) {
        self.containerIdentifier = containerIdentifier
    }

    public var container: CKContainer {
        CKContainer(identifier: containerIdentifier)
    }

    /// - Parameters:
    ///   - photoDownloadLimit: how many of the newest meals should have their photo cached.
    ///   - maxPhotoScan: how far back to keep looking for the newest meal that has a photo.
    public func fetchFeed(
        ownerName: String?,
        photoDownloadLimit: Int,
        maxPhotoScan: Int = 60
    ) async throws -> FetchedMealFeed {
        let database = container.sharedCloudDatabase
        let zones = try await database.allRecordZones()

        var entries: [Entry] = []
        var feedOwner = ownerName
        for zone in zones {
            do {
                entries += try await mealEntries(in: zone.zoneID, database: database)
            } catch let error as CKError where error.code == .unknownItem || error.code == .zoneNotFound {
                continue
            }
            if let name = await feedOwnerName(in: zone.zoneID, database: database) {
                feedOwner = name
            }
        }

        entries.sort { $0.meal.photographedAt > $1.meal.photographedAt }
        for index in entries.indices where entries[index].meal.ownerName == nil {
            entries[index].meal.ownerName = feedOwner
        }

        try await attachPhotos(
            to: &entries,
            database: database,
            photoDownloadLimit: photoDownloadLimit,
            maxPhotoScan: maxPhotoScan
        )

        let meals = entries.map(\.meal)
        let latest = LatestMealStore.newestPhotographedMeal(in: meals)
        return FetchedMealFeed(
            meals: meals,
            ownerName: feedOwner,
            zoneName: entries.first?.zoneID.zoneName ?? zones.first?.zoneID.zoneName,
            latestPhotographedMeal: latest?.meal,
            latestPhotoData: latest?.photo
        )
    }

    private struct Entry {
        var recordID: CKRecord.ID
        var zoneID: CKRecordZone.ID
        var changeTag: String?
        var meal: Meal
    }

    /// Metadata only (no assets), paged through every result: an unsorted, capped
    /// query can silently miss the newest records once the share grows.
    private func mealEntries(in zoneID: CKRecordZone.ID, database: CKDatabase) async throws -> [Entry] {
        let keys = [MealCloudKit.titleKey, MealCloudKit.photographedAtKey, MealCloudKit.ownerDisplayNameKey]
        let query = CKQuery(recordType: MealCloudKit.mealRecordType, predicate: NSPredicate(value: true))
        var entries: [Entry] = []
        var page = try await database.records(
            matching: query,
            inZoneWith: zoneID,
            desiredKeys: keys,
            resultsLimit: CKQueryOperation.maximumResults
        )
        var pages = 1
        while true {
            for (_, result) in page.matchResults {
                if case .success(let record) = result {
                    entries.append(entry(from: record, zoneID: zoneID))
                }
            }
            guard let cursor = page.queryCursor, pages < 50 else { break }
            page = try await database.records(
                continuingMatchFrom: cursor,
                desiredKeys: keys,
                resultsLimit: CKQueryOperation.maximumResults
            )
            pages += 1
        }
        return entries
    }

    private func entry(from record: CKRecord, zoneID: CKRecordZone.ID) -> Entry {
        let title = (record[MealCloudKit.titleKey] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let meal = Meal(
            id: record.recordID.recordName,
            title: (title?.isEmpty == false ? title : nil) ?? "Meal",
            photographedAt: record[MealCloudKit.photographedAtKey] as? Date ?? record.creationDate ?? Date(),
            ownerName: record[MealCloudKit.ownerDisplayNameKey] as? String
        )
        return Entry(recordID: record.recordID, zoneID: zoneID, changeTag: record.recordChangeTag, meal: meal)
    }

    private func feedOwnerName(in zoneID: CKRecordZone.ID, database: CKDatabase) async -> String? {
        let query = CKQuery(recordType: MealCloudKit.feedRecordType, predicate: NSPredicate(value: true))
        guard let (matched, _) = try? await database.records(
            matching: query,
            inZoneWith: zoneID,
            desiredKeys: [MealCloudKit.ownerDisplayNameKey],
            resultsLimit: 1
        ) else { return nil }
        for (_, result) in matched {
            if case .success(let record) = result,
               let name = record[MealCloudKit.ownerDisplayNameKey] as? String {
                return name
            }
        }
        return nil
    }

    /// Walks meals newest first, reusing cached photos and downloading the rest in small
    /// batches, until `photoDownloadLimit` meals are covered and a photographed meal is found.
    private func attachPhotos(
        to entries: inout [Entry],
        database: CKDatabase,
        photoDownloadLimit: Int,
        maxPhotoScan: Int
    ) async throws {
        let batchSize = 6
        var foundPhoto = false
        var start = 0
        while start < entries.count {
            let wantsMore = start < photoDownloadLimit || (!foundPhoto && start < maxPhotoScan)
            guard wantsMore else { break }
            let batch = start..<min(entries.count, start + batchSize)

            var missing: [CKRecord.ID] = []
            for index in batch {
                let name = LatestMealStore.photoFileName(mealID: entries[index].meal.id, version: entries[index].changeTag)
                if LatestMealStore.hasPhoto(named: name) {
                    entries[index].meal.photoFileName = name
                } else {
                    missing.append(entries[index].recordID)
                }
            }

            if !missing.isEmpty {
                let results = try await database.records(for: missing, desiredKeys: [MealCloudKit.photoKey])
                for index in batch where entries[index].meal.photoFileName == nil {
                    guard case .success(let record)? = results[entries[index].recordID],
                          let asset = record[MealCloudKit.photoKey] as? CKAsset,
                          let url = asset.fileURL,
                          let data = try? Data(contentsOf: url) else { continue }
                    entries[index].meal.photoFileName = LatestMealStore.savePhoto(
                        data,
                        mealID: entries[index].meal.id,
                        version: record.recordChangeTag ?? entries[index].changeTag
                    )
                }
            }

            if batch.contains(where: { entries[$0].meal.photoFileName != nil }) {
                foundPhoto = true
            }
            start = batch.upperBound
        }
    }
}

public enum AsyncTimeout {
    public struct Expired: Error {}

    public static func run<T: Sendable>(
        seconds: Double,
        _ operation: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask { try await operation() }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                throw Expired()
            }
            defer { group.cancelAll() }
            guard let result = try await group.next() else { throw Expired() }
            return result
        }
    }
}
