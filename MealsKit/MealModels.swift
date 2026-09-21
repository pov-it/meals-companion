import Foundation

/// CloudKit record contract for the meal-only share feed.
/// Trio (publisher) must write these records into the same container; this app never reads glucose, IOB, COB, or pump fields.
public enum MealCloudKit {
    public static let zoneName = "MealsZone"
    public static let mealRecordType = "Meal"
    public static let feedRecordType = "MealFeed"

    public static let titleKey = "title"
    public static let photographedAtKey = "photographedAt"
    public static let photoKey = "photo"
    public static let ownerDisplayNameKey = "ownerDisplayName"

    /// Keys this companion will not surface even if a publisher writes them.
    public static let ignoredPublisherKeys: Set<String> = [
        "glucose", "sgv", "iob", "cob", "insulin", "carbs",
        "reservoir", "pump", "nightscout", "loop", "trio"
    ]
}

public enum WidgetKind {
    public static let latestMeal = "MealsLatestMealWidget"
}

public struct Meal: Identifiable, Hashable, Sendable, Codable {
    public var id: String
    public var title: String
    public var photographedAt: Date
    public var ownerName: String?
    public var photoFileName: String?

    public init(
        id: String,
        title: String,
        photographedAt: Date,
        ownerName: String? = nil,
        photoFileName: String? = nil
    ) {
        self.id = id
        self.title = title
        self.photographedAt = photographedAt
        self.ownerName = ownerName
        self.photoFileName = photoFileName
    }
}

public struct PairingState: Codable, Equatable, Sendable {
    public var isPaired: Bool
    public var ownerName: String?
    public var shareURLString: String?
    public var acceptedAt: Date?
    public var zoneName: String?
    public var rootRecordName: String?

    public static let unpaired = PairingState(
        isPaired: false,
        ownerName: nil,
        shareURLString: nil,
        acceptedAt: nil,
        zoneName: nil,
        rootRecordName: nil
    )

    public init(
        isPaired: Bool,
        ownerName: String?,
        shareURLString: String?,
        acceptedAt: Date?,
        zoneName: String?,
        rootRecordName: String?
    ) {
        self.isPaired = isPaired
        self.ownerName = ownerName
        self.shareURLString = shareURLString
        self.acceptedAt = acceptedAt
        self.zoneName = zoneName
        self.rootRecordName = rootRecordName
    }
}

public struct LatestMealSnapshot: Codable, Equatable, Sendable {
    public var isPaired: Bool
    public var ownerName: String?
    public var meal: Meal?
    public var updatedAt: Date

    public static let empty = LatestMealSnapshot(
        isPaired: false,
        ownerName: nil,
        meal: nil,
        updatedAt: Date.distantPast
    )

    public init(isPaired: Bool, ownerName: String?, meal: Meal?, updatedAt: Date) {
        self.isPaired = isPaired
        self.ownerName = ownerName
        self.meal = meal
        self.updatedAt = updatedAt
    }
}

public enum RelativeTimestamp {
    public static func widgetLabel(from date: Date, now: Date = .now) -> String {
        let elapsed = now.timeIntervalSince(date)
        if elapsed < 60 { return "Just now" }
        if elapsed < 3600 {
            return "\(Int(elapsed / 60))m ago"
        }
        if Calendar.current.isDate(date, inSameDayAs: now) {
            return date.formatted(date: .omitted, time: .shortened)
        }
        if elapsed < 48 * 3600 {
            return "Yesterday"
        }
        return date.formatted(date: .abbreviated, time: .omitted)
    }

    public static func feedLabel(from date: Date, now: Date = .now) -> String {
        let relative = RelativeDateTimeFormatter()
        relative.unitsStyle = .full
        let relativeText = relative.localizedString(for: date, relativeTo: now)
        let clock = date.formatted(date: .omitted, time: .shortened)
        if Calendar.current.isDate(date, inSameDayAs: now) {
            return "\(clock) · \(relativeText)"
        }
        let day = date.formatted(date: .abbreviated, time: .omitted)
        return "\(day) · \(clock)"
    }
}

enum MealJSON {
    static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        return encoder
    }()

    static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        return decoder
    }()
}

public enum NotificationPreferences {
    public static let userVisibleDefaultsToOff = true

    public static var userVisibleEnabled: Bool {
        get { AppGroupStore.defaults.bool(forKey: Keys.userVisible) }
        set { AppGroupStore.defaults.set(newValue, forKey: Keys.userVisible) }
    }

    private enum Keys {
        static let userVisible = "notifications.userVisibleEnabled"
    }
}
