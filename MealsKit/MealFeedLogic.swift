import CoreGraphics
import Foundation
import ImageIO

/// Pure feed ordering, record mapping, and image downsampling used by the app
/// and the widget. Kept free of CloudKit and UIKit so it can be tested with `swiftc`.
public enum MealFeedOrdering {
    /// Newest `photographedAt` first. Duplicate ids keep the first (newest) copy.
    public static func deduplicatedNewestFirst(_ meals: [Meal]) -> [Meal] {
        let sorted = meals.sorted { lhs, rhs in
            if lhs.photographedAt != rhs.photographedAt {
                return lhs.photographedAt > rhs.photographedAt
            }
            return lhs.id < rhs.id
        }
        var seen = Set<String>()
        var unique: [Meal] = []
        unique.reserveCapacity(sorted.count)
        for meal in sorted {
            let id = meal.id.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !id.isEmpty, seen.insert(id).inserted else { continue }
            unique.append(meal)
        }
        return unique
    }

    /// Widget and app hero must show the same meal: the newest by `photographedAt`.
    /// A photo is attached only when it belongs to that meal — never an older plate.
    public static func displayLatest(in meals: [Meal]) -> Meal? {
        deduplicatedNewestFirst(meals).first
    }
}

/// Maps loosely-typed CloudKit / JSON field values onto `Meal` without crashing.
public enum MealRecordDecoder {
    public static func title(from value: Any?) -> String {
        if let text = (value as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty {
            return text
        }
        return "Meal"
    }

    public static func ownerName(from value: Any?) -> String? {
        let text = (value as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let text, !text.isEmpty else { return nil }
        return text
    }

    public static func date(from value: Any?, fallback: Date?) -> Date {
        if let date = value as? Date { return date }
        if let number = value as? NSNumber {
            let raw = number.doubleValue
            if raw > 1_000_000_000_000 {
                return Date(timeIntervalSince1970: raw / 1000)
            }
            if raw > 1_000_000 {
                return Date(timeIntervalSince1970: raw)
            }
        }
        if let raw = value as? Double {
            if raw > 1_000_000_000_000 {
                return Date(timeIntervalSince1970: raw / 1000)
            }
            if raw > 1_000_000 {
                return Date(timeIntervalSince1970: raw)
            }
        }
        if let raw = value as? Int {
            return date(from: Double(raw), fallback: fallback)
        }
        if let text = value as? String {
            let iso = ISO8601DateFormatter()
            iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let date = iso.date(from: text) { return date }
            iso.formatOptions = [.withInternetDateTime]
            if let date = iso.date(from: text) { return date }
        }
        return fallback ?? Date()
    }

    public static func meal(
        id: String,
        title: Any?,
        photographedAt: Any?,
        creationDate: Date?,
        ownerName: Any?,
        photoFileName: String? = nil
    ) -> Meal? {
        let trimmedID = id.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedID.isEmpty else { return nil }
        return Meal(
            id: trimmedID,
            title: Self.title(from: title),
            photographedAt: date(from: photographedAt, fallback: creationDate),
            ownerName: Self.ownerName(from: ownerName),
            photoFileName: photoFileName
        )
    }

    static func decodeJSONDate<Key: CodingKey>(
        _ container: KeyedDecodingContainer<Key>,
        forKey key: Key
    ) -> Date? {
        if let date = try? container.decode(Date.self, forKey: key) { return date }
        if let raw = try? container.decode(Double.self, forKey: key) {
            return date(from: raw, fallback: nil)
        }
        if let raw = try? container.decode(Int.self, forKey: key) {
            return date(from: Double(raw), fallback: nil)
        }
        if let text = try? container.decode(String.self, forKey: key) {
            return date(from: text, fallback: nil)
        }
        return nil
    }
}

public enum MealPhotoCache {
    /// File name for a meal photo. `version` is the CloudKit record change tag, so an
    /// edited record gets a fresh download while an unchanged one is served from disk.
    public static func fileName(mealID: String, version: String?) -> String {
        let raw = version.map { "\(mealID)-\($0)" } ?? mealID
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_."))
        let safe = String(raw.unicodeScalars.map { allowed.contains($0) ? Character($0) : "_" })
        return "\(safe).jpg"
    }
}

/// Downsamples with ImageIO so a 2048px CloudKit asset never fully decodes on
/// the main thread (UIGraphicsImageRenderer of HD photos was a jetsam risk).
public enum MealImageTranscoder {
    public static func jpeg(from data: Data, maxDimension: CGFloat) -> Data? {
        guard !data.isEmpty, maxDimension > 0 else { return nil }
        return autoreleasepool {
            let srcOptions = [kCGImageSourceShouldCache: false] as CFDictionary
            guard let source = CGImageSourceCreateWithData(data as CFData, srcOptions) else { return nil }
            let size = max(1, Int(maxDimension.rounded(.down)))
            let thumbOptions: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceShouldCacheImmediately: true,
                kCGImageSourceThumbnailMaxPixelSize: size
            ]
            guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, thumbOptions as CFDictionary) else {
                return nil
            }
            let destData = NSMutableData()
            guard let destination = CGImageDestinationCreateWithData(
                destData,
                "public.jpeg" as CFString,
                1,
                nil
            ) else { return nil }
            let destOptions = [kCGImageDestinationLossyCompressionQuality: 0.82] as CFDictionary
            CGImageDestinationAddImage(destination, image, destOptions)
            guard CGImageDestinationFinalize(destination) else { return nil }
            return destData as Data
        }
    }
}

public enum MealsTimelineSchedule {
    public static let defaultHorizon: TimeInterval = 24 * 3600

    public static func reloadInterval(widgetCloudKitEnabled: Bool) -> TimeInterval {
        widgetCloudKitEnabled ? 30 * 60 : 60 * 60
    }

    /// Entries only where `RelativeTimestamp.widgetLabel` would change, covering ~24h.
    public static func entryDates(
        for meal: Meal?,
        from now: Date,
        horizon: TimeInterval = defaultHorizon
    ) -> [Date] {
        guard let meal else { return [now] }
        let end = now.addingTimeInterval(horizon)
        let taken = meal.photographedAt
        var dates: [Date] = [
            now,
            taken.addingTimeInterval(60),
            taken.addingTimeInterval(3600),
            taken.addingTimeInterval(48 * 3600)
        ]
        for minutes in stride(from: 5, to: 60, by: 5) {
            dates.append(taken.addingTimeInterval(TimeInterval(minutes * 60)))
        }
        var midnight = Calendar.current.startOfDay(for: now)
        for _ in 0..<2 {
            guard let next = Calendar.current.date(byAdding: .day, value: 1, to: midnight) else { break }
            dates.append(next)
            midnight = next
        }
        return Array(Set(dates.filter { $0 >= now && $0 <= end })).sorted()
    }
}

/// Maps CloudKit / timeout failures to copy the companion can show. Numeric codes
/// match `CKError.Code` so this file does not import CloudKit.
public enum CloudKitUserFacingError {
    public static let quotaExceededCode = 25
    public static let networkUnavailableCode = 3
    public static let networkFailureCode = 4
    public static let notAuthenticatedCode = 9
    public static let quotaExceededOnOwnerHint =
        "If meals stopped updating, also check iCloud storage on the publisher’s iPhone (Settings → Apple Account → iCloud → Manage Account Storage). A full iCloud account cannot upload new meal photos."

    public static func message(for error: Error) -> String {
        if error is FetchTimeout.Expired {
            return "Reload timed out. Pull to refresh to try again."
        }
        let ns = error as NSError
        return message(code: ns.code, fallback: error.localizedDescription, domain: ns.domain)
    }

    public static func message(code: Int, fallback: String, domain: String? = nil) -> String {
        let isCloudKit = domain == nil
            || domain == "CKErrorDomain"
            || domain == "CKError"
        switch code {
        case quotaExceededCode where isCloudKit:
            return "iCloud storage is full on this iPhone. Free space in Settings → Apple Account → iCloud → Manage Account Storage, then reload. \(quotaExceededOnOwnerHint)"
        case networkUnavailableCode, networkFailureCode:
            return "No network. Check the connection and reload."
        case notAuthenticatedCode:
            return "Sign in to iCloud on this iPhone to load meals."
        default:
            return fallback
        }
    }
}

public enum FetchTimeout {
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
