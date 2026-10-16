import Foundation
import CoreGraphics
import ImageIO

/// Command-line tests for MealsKit feed logic. Compiled with `swiftc` in CI:
/// `swiftc -o run MealsKit/MealModels.swift MealsKit/MealFeedLogic.swift MealsKitTests/MealFeedLogicTests.swift && ./run`
@main
enum MealFeedLogicTests {
    static func main() {
        testDedupeAndSort()
        testDisplayLatestMatchesAppHero()
        testNeverPairsOlderPhotoWithNewerMeal()
        testMissingFieldsDecode()
        testJSONRoundTripAndExtraKeys()
        testISODateAndNumericDate()
        testPhotoFileNameSanitizes()
        testQuotaMessage()
        testTimelineSchedule()
        testImageTranscoder()
        testIgnoredPublisherKeysStayIgnored()
        print("All MealFeedLogic tests passed.")
    }

    private static func fail(_ message: String) -> Never {
        fputs("FAIL: \(message)\n", stderr)
        exit(1)
    }

    private static func expect(_ condition: Bool, _ message: String) {
        if !condition { fail(message) }
    }

    private static func meal(
        id: String,
        title: String = "Meal",
        minutesAgo: Double,
        photo: String? = nil
    ) -> Meal {
        Meal(
            id: id,
            title: title,
            photographedAt: Date(timeIntervalSince1970: 1_700_000_000 - minutesAgo * 60),
            ownerName: "Publisher",
            photoFileName: photo
        )
    }

    static func testDedupeAndSort() {
        let older = meal(id: "a", title: "Older", minutesAgo: 120, photo: "a.jpg")
        let newer = meal(id: "b", title: "Newer", minutesAgo: 5)
        let dupNewer = meal(id: "b", title: "Newer copy", minutesAgo: 1)
        let emptyID = meal(id: "  ", title: "Skip", minutesAgo: 0)
        let ordered = MealFeedOrdering.deduplicatedNewestFirst([older, newer, dupNewer, emptyID])
        expect(ordered.map(\.id) == ["b", "a"], "dedupe newest-first ids \(ordered.map(\.id))")
        expect(ordered.first?.title == "Newer copy", "duplicate id keeps the newer copy")
    }

    static func testDisplayLatestMatchesAppHero() {
        let photolessNew = meal(id: "new", title: "Soup", minutesAgo: 2)
        let photographedOld = meal(id: "old", title: "Pasta", minutesAgo: 180, photo: "old.jpg")
        let latest = MealFeedOrdering.displayLatest(in: [photographedOld, photolessNew])
        expect(latest?.id == "new", "latest is the newest meal even without a photo")
        expect(latest?.title == "Soup", "latest title is Soup")
    }

    static func testNeverPairsOlderPhotoWithNewerMeal() {
        let photolessNew = meal(id: "new", title: "Soup", minutesAgo: 2)
        let photographedOld = meal(id: "old", title: "Pasta", minutesAgo: 180, photo: "old.jpg")
        let latest = MealFeedOrdering.displayLatest(in: [photolessNew, photographedOld])
        expect(latest?.photoFileName == nil, "must not attach the older plate to the newer meal")
        expect(latest?.id != photographedOld.id, "widget meal is not the older photographed one")
    }

    static func testMissingFieldsDecode() {
        let decoded = MealRecordDecoder.meal(
            id: "ck-1",
            title: "  ",
            photographedAt: nil,
            creationDate: Date(timeIntervalSince1970: 1_700_000_000),
            ownerName: nil
        )
        expect(decoded?.title == "Meal", "empty title becomes Meal")
        expect(decoded?.photographedAt == Date(timeIntervalSince1970: 1_700_000_000), "falls back to creationDate")
        expect(MealRecordDecoder.meal(id: " ", title: "X", photographedAt: Date(), creationDate: nil, ownerName: nil) == nil, "blank id is rejected")
        let fromNumber = MealRecordDecoder.date(from: NSNumber(value: 1_700_000_000), fallback: nil)
        expect(abs(fromNumber.timeIntervalSince1970 - 1_700_000_000) < 0.5, "numeric epoch seconds")
    }

    static func testJSONRoundTripAndExtraKeys() {
        let json = """
        {"id":"m1","title":"Oats","photographedAt":1700000000,"ownerName":"Publisher","photoFileName":null,"glucose":99,"iob":1.2}
        """.data(using: .utf8)!
        do {
            let meal = try MealJSON.decoder.decode(Meal.self, from: json)
            expect(meal.id == "m1", "id")
            expect(meal.title == "Oats", "title")
            expect(meal.photoFileName == nil, "missing photo stays nil")
        } catch {
            fail("extra publisher keys must not fail decode: \(error)")
        }

        let wrongTypes = """
        {"id":"m4","title":12,"photographedAt":1700000000,"ownerName":false}
        """.data(using: .utf8)!
        do {
            let meal = try MealJSON.decoder.decode(Meal.self, from: wrongTypes)
            expect(meal.id == "m4", "wrong-type fields still keep id")
            expect(meal.title == "Meal", "non-string title becomes Meal")
        } catch {
            fail("wrong field types must not crash decode: \(error)")
        }

        let sparse = """
        {"id":"m2"}
        """.data(using: .utf8)!
        do {
            let meal = try MealJSON.decoder.decode(Meal.self, from: sparse)
            expect(meal.title == "Meal", "missing title")
            expect(meal.photographedAt == Date.distantPast, "missing date")
        } catch {
            fail("sparse meal JSON must decode: \(error)")
        }
    }

    static func testISODateAndNumericDate() {
        let iso = """
        {"id":"m3","title":"Toast","photographedAt":"2026-10-03T12:00:00Z"}
        """.data(using: .utf8)!
        do {
            let meal = try MealJSON.decoder.decode(Meal.self, from: iso)
            expect(meal.title == "Toast", "iso title")
            let expected = ISO8601DateFormatter().date(from: "2026-10-03T12:00:00Z")
            expect(meal.photographedAt == expected, "iso date parsed")
        } catch {
            fail("ISO-8601 photographedAt must decode: \(error)")
        }
    }

    static func testPhotoFileNameSanitizes() {
        let name = MealPhotoCache.fileName(mealID: "meal/id:1", version: "a b/c")
        expect(name == "meal_id_1-a_b_c.jpg", "sanitized \(name)")
        expect(MealPhotoCache.fileName(mealID: "plain", version: nil) == "plain.jpg", "nil version")
    }

    static func testQuotaMessage() {
        let text = CloudKitUserFacingError.message(
            code: CloudKitUserFacingError.quotaExceededCode,
            fallback: "CKError",
            domain: "CKErrorDomain"
        )
        expect(text.contains("iCloud storage is full"), "quota copy")
        expect(text.contains("Manage Account Storage"), "how to verify")
        expect(text.contains("publisher"), "owner-side quota hint")
        let timeout = CloudKitUserFacingError.message(for: FetchTimeout.Expired())
        expect(timeout.contains("timed out"), "timeout copy: \(timeout)")
    }

    static func testTimelineSchedule() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let none = MealsTimelineSchedule.entryDates(for: nil, from: now)
        expect(none == [now], "empty meal is just now")
        let meal = Meal(id: "t", title: "T", photographedAt: now.addingTimeInterval(-120))
        let dates = MealsTimelineSchedule.entryDates(for: meal, from: now)
        expect(dates.first == now, "first is now")
        expect(dates == dates.sorted(), "sorted")
        expect(dates.last! <= now.addingTimeInterval(24 * 3600), "within 24h")
        expect(MealsTimelineSchedule.reloadInterval(widgetCloudKitEnabled: false) == 3600, "hourly without widget CloudKit")
        expect(MealsTimelineSchedule.reloadInterval(widgetCloudKitEnabled: true) == 1800, "30 min with widget CloudKit")
    }

    static func testImageTranscoder() {
        expect(MealImageTranscoder.jpeg(from: Data(), maxDimension: 800) == nil, "empty data")
        expect(MealImageTranscoder.jpeg(from: Data([0x00, 0x01, 0x02]), maxDimension: 800) == nil, "garbage bytes")
        guard let png = tinyPNG() else { fail("could not make fixture PNG") }
        guard let jpeg = MealImageTranscoder.jpeg(from: png, maxDimension: 32) else {
            fail("valid PNG should downsample to JPEG")
        }
        expect(jpeg.count > 20, "jpeg has bytes")
        expect(jpeg.starts(with: [0xFF, 0xD8]), "JPEG magic")
    }

    static func testIgnoredPublisherKeysStayIgnored() {
        expect(MealCloudKit.ignoredPublisherKeys.contains("glucose"), "glucose ignored")
        expect(MealCloudKit.ignoredPublisherKeys.contains("iob"), "iob ignored")
        expect(!MealCloudKit.ignoredPublisherKeys.contains("title"), "title is a real field")
        expect(MealCloudKit.photoKey == "photo", "photo field name")
        expect(MealCloudKit.photographedAtKey == "photographedAt", "date field name")
    }

    private static func tinyPNG() -> Data? {
        let width = 8
        let height = 8
        let bytesPerPixel = 4
        var pixels = [UInt8](repeating: 200, count: width * height * bytesPerPixel)
        for index in stride(from: 3, to: pixels.count, by: 4) { pixels[index] = 255 }
        guard let provider = CGDataProvider(data: Data(pixels) as CFData) else { return nil }
        guard let image = CGImage(
            width: width,
            height: height,
            bitsPerComponent: 8,
            bitsPerPixel: 32,
            bytesPerRow: width * bytesPerPixel,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
            provider: provider,
            decode: nil,
            shouldInterpolate: false,
            intent: .defaultIntent
        ) else { return nil }
        let destData = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(destData, "public.png" as CFString, 1, nil) else {
            return nil
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return destData as Data
    }
}
