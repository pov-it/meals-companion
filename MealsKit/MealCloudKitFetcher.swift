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
    ///   - maxPhotoScan: how far back to keep looking for a meal that has a photo.
    public func fetchFeed(
        ownerName: String?,
        photoDownloadLimit: Int,
        maxPhotoScan: Int = 60
    ) async throws -> FetchedMealFeed {
        let database = container.sharedCloudDatabase
        let zones: [CKRecordZone]
        do {
            zones = try await database.allRecordZones()
        } catch {
            MealsLog.cloudKit.error("Could not list shared zones: \(error.localizedDescription, privacy: .public)")
            throw error
        }

        let orderedZones = zones.sorted { lhs, rhs in
            if lhs.zoneID.zoneName == MealCloudKit.zoneName { return true }
            if rhs.zoneID.zoneName == MealCloudKit.zoneName { return false }
            return lhs.zoneID.zoneName < rhs.zoneID.zoneName
        }

        var entries: [Entry] = []
        var feedOwner = ownerName
        var lastZoneError: Error?
        for zone in orderedZones {
            do {
                entries += try await mealEntries(in: zone.zoneID, database: database)
            } catch let error as CKError where error.code == .unknownItem || error.code == .zoneNotFound {
                continue
            } catch {
                lastZoneError = error
                MealsLog.cloudKit.error(
                    "Meal query failed in \(zone.zoneID.zoneName, privacy: .public): \(error.localizedDescription, privacy: .public)"
                )
                continue
            }
            if let name = await feedOwnerName(in: zone.zoneID, database: database) {
                feedOwner = name
            }
        }

        if entries.isEmpty, let lastZoneError {
            throw lastZoneError
        }

        var mealsByID: [String: Entry] = [:]
        for entry in entries {
            let id = entry.meal.id
            if let existing = mealsByID[id] {
                if entry.meal.photographedAt > existing.meal.photographedAt {
                    mealsByID[id] = entry
                }
            } else {
                mealsByID[id] = entry
            }
        }
        var uniqueEntries = Array(mealsByID.values)
        uniqueEntries.sort { $0.meal.photographedAt > $1.meal.photographedAt }
        for index in uniqueEntries.indices where uniqueEntries[index].meal.ownerName == nil {
            uniqueEntries[index].meal.ownerName = feedOwner
        }

        await attachPhotos(
            to: &uniqueEntries,
            database: database,
            photoDownloadLimit: photoDownloadLimit,
            maxPhotoScan: maxPhotoScan
        )

        let meals = MealFeedOrdering.deduplicatedNewestFirst(uniqueEntries.map(\.meal))
        let latestPhotographed = LatestMealStore.newestPhotographedMeal(in: meals)
        return FetchedMealFeed(
            meals: meals,
            ownerName: feedOwner,
            zoneName: uniqueEntries.first?.zoneID.zoneName ?? orderedZones.first?.zoneID.zoneName,
            latestPhotographedMeal: latestPhotographed?.meal,
            latestPhotoData: latestPhotographed?.photo
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
                if case .success(let record) = result, let mapped = entry(from: record, zoneID: zoneID) {
                    entries.append(mapped)
                }
            }
            guard let cursor = page.queryCursor, pages < 50 else { break }
            do {
                page = try await database.records(
                    continuingMatchFrom: cursor,
                    desiredKeys: keys,
                    resultsLimit: CKQueryOperation.maximumResults
                )
            } catch {
                MealsLog.cloudKit.error("Meal page \(pages, privacy: .public) stopped: \(error.localizedDescription, privacy: .public)")
                break
            }
            pages += 1
        }
        return entries
    }

    private func entry(from record: CKRecord, zoneID: CKRecordZone.ID) -> Entry? {
        guard let meal = MealRecordDecoder.meal(
            id: record.recordID.recordName,
            title: record[MealCloudKit.titleKey],
            photographedAt: record[MealCloudKit.photographedAtKey],
            creationDate: record.creationDate,
            ownerName: record[MealCloudKit.ownerDisplayNameKey]
        ) else { return nil }
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

    /// Walks meals newest first, reusing cached photos and downloading the rest one at a
    /// time. Photo failures never fail the feed — a missing `CKAsset` is a meal without a plate.
    private func attachPhotos(
        to entries: inout [Entry],
        database: CKDatabase,
        photoDownloadLimit: Int,
        maxPhotoScan: Int
    ) async {
        var foundPhoto = false
        var start = 0
        while start < entries.count {
            let wantsMore = start < photoDownloadLimit || (!foundPhoto && start < maxPhotoScan)
            guard wantsMore else { break }
            let index = start
            let name = LatestMealStore.photoFileName(mealID: entries[index].meal.id, version: entries[index].changeTag)
            if LatestMealStore.hasPhoto(named: name) {
                entries[index].meal.photoFileName = name
                foundPhoto = true
                start += 1
                continue
            }

            do {
                let results = try await database.records(
                    for: [entries[index].recordID],
                    desiredKeys: [MealCloudKit.photoKey]
                )
                if case .success(let record)? = results[entries[index].recordID],
                   let asset = record[MealCloudKit.photoKey] as? CKAsset,
                   let url = asset.fileURL,
                   let data = try? Data(contentsOf: url),
                   let saved = LatestMealStore.savePhoto(
                    data,
                    mealID: entries[index].meal.id,
                    version: record.recordChangeTag ?? entries[index].changeTag
                   ) {
                    entries[index].meal.photoFileName = saved
                    foundPhoto = true
                }
            } catch {
                MealsLog.cloudKit.error(
                    "Photo download skipped: \(error.localizedDescription, privacy: .public)"
                )
            }
            start += 1
        }
    }
}
