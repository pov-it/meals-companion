import Foundation
import UIKit

public enum RuntimeConfig {
    public static var appGroupIdentifier: String {
        plistValue("MealsAppGroupIdentifier") ?? "group.org.pov-it.Q6QCL8J6FN.meals"
    }

    public static var cloudKitContainerIdentifier: String {
        plistValue("MealsCloudKitContainerIdentifier") ?? "iCloud.org.pov-it.Q6QCL8J6FN.meals"
    }

    /// Only true in the widget when it was signed with the iCloud entitlement
    /// (`MEALS_WIDGET_CLOUDKIT = YES`). Touching CKContainer without it crashes the extension.
    public static var widgetCloudKitEnabled: Bool {
        guard let value = plistValue("MealsWidgetCloudKitEnabled")?.uppercased() else { return false }
        return value == "YES" || value == "1" || value == "TRUE"
    }

    private static func plistValue(_ key: String) -> String? {
        guard let value = Bundle.main.object(forInfoDictionaryKey: key) as? String else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

public enum AppGroupStore {
    public static var containerURL: URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: RuntimeConfig.appGroupIdentifier)
    }

    public static var defaults: UserDefaults {
        UserDefaults(suiteName: RuntimeConfig.appGroupIdentifier) ?? .standard
    }

    public static var photosDirectory: URL? {
        guard let containerURL else { return nil }
        let directory = containerURL.appendingPathComponent("Photos", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }
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

public enum PairingStore {
    private static let key = "pairing.state"

    public static func load() -> PairingState {
        guard let data = AppGroupStore.defaults.data(forKey: key) else { return .unpaired }
        return (try? MealJSON.decoder.decode(PairingState.self, from: data)) ?? .unpaired
    }

    public static func save(_ state: PairingState) {
        let data = try? MealJSON.encoder.encode(state)
        AppGroupStore.defaults.set(data, forKey: key)
    }

    public static func clear() {
        AppGroupStore.defaults.removeObject(forKey: key)
    }
}

public enum LatestMealStore {
    private static let snapshotFile = "latest-meal.json"
    private static let mealsFile = "meals.json"
    private static let latestPhotoFile = "latest-meal.jpg"

    public static func snapshot() -> LatestMealSnapshot {
        guard
            let url = AppGroupStore.containerURL?.appendingPathComponent(snapshotFile),
            let data = try? Data(contentsOf: url),
            let decoded = try? MealJSON.decoder.decode(LatestMealSnapshot.self, from: data)
        else {
            let pairing = PairingStore.load()
            return LatestMealSnapshot(
                isPaired: pairing.isPaired,
                ownerName: pairing.ownerName,
                meal: nil,
                updatedAt: pairing.acceptedAt ?? .distantPast
            )
        }
        return decoded
    }

    public static func loadMeals() -> [Meal] {
        guard
            let url = AppGroupStore.containerURL?.appendingPathComponent(mealsFile),
            let data = try? Data(contentsOf: url),
            let meals = try? MealJSON.decoder.decode([Meal].self, from: data)
        else {
            if let meal = snapshot().meal { return [meal] }
            return []
        }
        return MealFeedOrdering.deduplicatedNewestFirst(meals.filter { !$0.id.isEmpty })
    }

    public static func latestPhotoURL() -> URL? {
        AppGroupStore.containerURL?.appendingPathComponent(latestPhotoFile)
    }

    public static func loadLatestImage() -> UIImage? {
        guard let url = latestPhotoURL(), let data = try? Data(contentsOf: url) else { return nil }
        return UIImage(data: data)
    }

    public static func photo(for meal: Meal) -> UIImage? {
        if let name = meal.photoFileName,
           let directory = AppGroupStore.photosDirectory {
            let url = directory.appendingPathComponent(name)
            if let data = try? Data(contentsOf: url), let image = UIImage(data: data) {
                return image
            }
        }
        if snapshot().meal?.id == meal.id {
            return loadLatestImage()
        }
        return nil
    }

    /// Newest meal that has a photo on disk. Used for optional gallery thumbnails,
    /// not for choosing which meal the widget displays.
    public static func newestPhotographedMeal(in meals: [Meal]) -> (meal: Meal, photo: Data)? {
        for meal in MealFeedOrdering.deduplicatedNewestFirst(meals) where meal.photoFileName != nil {
            if let data = photoData(for: meal) {
                return (meal, data)
            }
        }
        return nil
    }

    public static func save(meals: [Meal], pairing: PairingState) {
        PairingStore.save(pairing)
        let ordered = MealFeedOrdering.deduplicatedNewestFirst(meals)
        saveMeals(ordered)
        let latest = MealFeedOrdering.displayLatest(in: ordered)
        saveSnapshot(
            latestMeal: latest,
            latestPhoto: latest.flatMap(photoData(for:)),
            pairing: pairing
        )
    }

    public static func saveMeals(_ meals: [Meal]) {
        guard let container = AppGroupStore.containerURL,
              let data = try? MealJSON.encoder.encode(meals) else { return }
        try? data.write(to: container.appendingPathComponent(mealsFile), options: .atomic)
    }

    public static func saveSnapshot(latestMeal: Meal?, latestPhoto: Data?, pairing: PairingState) {
        guard let container = AppGroupStore.containerURL else { return }
        let photoURL = container.appendingPathComponent(latestPhotoFile)
        if latestMeal != nil, let latestPhoto, let resized = widgetJPEG(from: latestPhoto) {
            try? resized.write(to: photoURL, options: .atomic)
        } else {
            try? FileManager.default.removeItem(at: photoURL)
        }
        let snapshot = LatestMealSnapshot(
            isPaired: pairing.isPaired,
            ownerName: pairing.ownerName,
            meal: latestMeal,
            updatedAt: Date()
        )
        if let data = try? MealJSON.encoder.encode(snapshot) {
            try? data.write(to: container.appendingPathComponent(snapshotFile), options: .atomic)
        }
    }

    /// File name for a meal photo. `version` is the CloudKit record change tag, so an
    /// edited record gets a fresh download while an unchanged one is served from disk.
    public static func photoFileName(mealID: String, version: String?) -> String {
        MealPhotoCache.fileName(mealID: mealID, version: version)
    }

    public static func hasPhoto(named name: String) -> Bool {
        guard let directory = AppGroupStore.photosDirectory else { return false }
        return FileManager.default.fileExists(atPath: directory.appendingPathComponent(name).path)
    }

    public static func photoData(for meal: Meal) -> Data? {
        guard let name = meal.photoFileName, let directory = AppGroupStore.photosDirectory else { return nil }
        return try? Data(contentsOf: directory.appendingPathComponent(name))
    }

    public static func savePhoto(_ data: Data, mealID: String, version: String? = nil) -> String? {
        guard let directory = AppGroupStore.photosDirectory else { return nil }
        let name = photoFileName(mealID: mealID, version: version)
        let url = directory.appendingPathComponent(name)
        if let jpeg = widgetJPEG(from: data, maxDimension: 1600),
           (try? jpeg.write(to: url, options: .atomic)) != nil {
            return name
        }
        return nil
    }

    public static func prunePhotos(keeping names: Set<String>) {
        guard let directory = AppGroupStore.photosDirectory,
              let files = try? FileManager.default.contentsOfDirectory(atPath: directory.path) else { return }
        for file in files where !names.contains(file) {
            try? FileManager.default.removeItem(at: directory.appendingPathComponent(file))
        }
    }

    public static func clear() {
        PairingStore.clear()
        NotificationPreferences.userVisibleEnabled = false
        guard let container = AppGroupStore.containerURL else { return }
        for name in [snapshotFile, mealsFile, latestPhotoFile] {
            try? FileManager.default.removeItem(at: container.appendingPathComponent(name))
        }
        if let photos = AppGroupStore.photosDirectory {
            try? FileManager.default.removeItem(at: photos)
        }
    }

    public static func widgetJPEG(from data: Data, maxDimension: CGFloat = 800) -> Data? {
        MealImageTranscoder.jpeg(from: data, maxDimension: maxDimension)
    }

#if DEBUG
    public static func saveSampleMealForPreviews() {
        let image = samplePlateImage()
        let data = image.jpegData(compressionQuality: 0.85)
        var meal = Meal(
            id: "sample-preview",
            title: "Overnight oats",
            photographedAt: Date().addingTimeInterval(-2 * 3600),
            ownerName: "Publisher",
            photoFileName: nil
        )
        if let data, let name = savePhoto(data, mealID: meal.id) {
            meal.photoFileName = name
        }
        let pairing = PairingState(
            isPaired: true,
            ownerName: "Publisher",
            shareURLString: nil,
            acceptedAt: Date(),
            zoneName: MealCloudKit.zoneName,
            rootRecordName: "sample"
        )
        save(meals: [meal], pairing: pairing)
    }

    private static func samplePlateImage() -> UIImage {
        let size = CGSize(width: 800, height: 800)
        let renderer = UIGraphicsImageRenderer(size: size)
        return renderer.image { context in
            UIColor(red: 0.97, green: 0.94, blue: 0.89, alpha: 1).setFill()
            context.fill(CGRect(origin: .zero, size: size))
            UIColor(red: 0.77, green: 0.36, blue: 0.15, alpha: 1).setFill()
            context.cgContext.fillEllipse(in: CGRect(x: 140, y: 140, width: 520, height: 520))
            UIColor(red: 0.93, green: 0.84, blue: 0.70, alpha: 1).setFill()
            context.cgContext.fillEllipse(in: CGRect(x: 210, y: 210, width: 380, height: 380))
        }
    }
#endif
}
