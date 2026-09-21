import Foundation
import UIKit

public enum RuntimeConfig {
    public static var appGroupIdentifier: String {
        plistValue("MealsAppGroupIdentifier") ?? "group.org.pov-it.Q6QCL8J6FN.meals"
    }

    public static var cloudKitContainerIdentifier: String {
        plistValue("MealsCloudKitContainerIdentifier") ?? "iCloud.org.pov-it.Q6QCL8J6FN.meals"
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
        return meals
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

    public static func save(meals: [Meal], latestPhoto: Data?, pairing: PairingState) {
        PairingStore.save(pairing)
        if let container = AppGroupStore.containerURL {
            let snapshot = LatestMealSnapshot(
                isPaired: pairing.isPaired,
                ownerName: pairing.ownerName,
                meal: meals.first,
                updatedAt: Date()
            )
            if let data = try? MealJSON.encoder.encode(snapshot) {
                try? data.write(to: container.appendingPathComponent(snapshotFile), options: .atomic)
            }
            if let data = try? MealJSON.encoder.encode(meals) {
                try? data.write(to: container.appendingPathComponent(mealsFile), options: .atomic)
            }
            let photoURL = container.appendingPathComponent(latestPhotoFile)
            if let latestPhoto, let resized = Self.widgetJPEG(from: latestPhoto) {
                try? resized.write(to: photoURL, options: .atomic)
            } else if latestPhoto == nil {
                try? FileManager.default.removeItem(at: photoURL)
            }
        }
    }

    public static func savePhoto(_ data: Data, mealID: String) -> String? {
        guard let directory = AppGroupStore.photosDirectory else { return nil }
        let name = "\(mealID).jpg"
        let url = directory.appendingPathComponent(name)
        if let jpeg = widgetJPEG(from: data, maxDimension: 1600) {
            try? jpeg.write(to: url, options: .atomic)
            return name
        }
        return nil
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
        guard let image = UIImage(data: data) else { return data }
        let size = image.size
        let longest = max(size.width, size.height)
        let scale = longest > maxDimension ? maxDimension / longest : 1
        let target = CGSize(width: max(1, size.width * scale), height: max(1, size.height * scale))
        let renderer = UIGraphicsImageRenderer(size: target)
        let rendered = renderer.image { _ in
            image.draw(in: CGRect(origin: .zero, size: target))
        }
        return rendered.jpegData(compressionQuality: 0.82)
    }

#if DEBUG
    public static func saveSampleMealForPreviews() {
        let image = samplePlateImage()
        let data = image.jpegData(compressionQuality: 0.85)
        var meal = Meal(
            id: "sample-preview",
            title: "Overnight oats",
            photographedAt: Date().addingTimeInterval(-2 * 3600),
            ownerName: "Marijn",
            photoFileName: nil
        )
        if let data, let name = savePhoto(data, mealID: meal.id) {
            meal.photoFileName = name
        }
        let pairing = PairingState(
            isPaired: true,
            ownerName: "Marijn",
            shareURLString: nil,
            acceptedAt: Date(),
            zoneName: MealCloudKit.zoneName,
            rootRecordName: "sample"
        )
        save(meals: [meal], latestPhoto: data, pairing: pairing)
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
