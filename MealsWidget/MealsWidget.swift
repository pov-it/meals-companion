import SwiftUI
import UIKit
import WidgetKit

struct MealsWidgetEntry: TimelineEntry {
    let date: Date
    let snapshot: LatestMealSnapshot
    let image: UIImage?
}

struct MealsTimelineProvider: TimelineProvider {
    func placeholder(in context: Context) -> MealsWidgetEntry {
        MealsWidgetEntry(date: Date(), snapshot: .empty, image: nil)
    }

    func getSnapshot(in context: Context, completion: @escaping (MealsWidgetEntry) -> Void) {
        completion(currentEntry())
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<MealsWidgetEntry>) -> Void) {
        Task {
            await WidgetCloudKitRefresh.run()
            let now = Date()
            let snapshot = LatestMealStore.snapshot()
            let image = LatestMealStore.loadLatestImage()
            let entries = MealsTimelineSchedule.entryDates(for: snapshot.meal, from: now).map {
                MealsWidgetEntry(date: $0, snapshot: snapshot, image: image)
            }
            let reload = now.addingTimeInterval(MealsTimelineSchedule.reloadInterval)
            completion(Timeline(entries: entries, policy: .after(reload)))
        }
    }

    private func currentEntry() -> MealsWidgetEntry {
        let snapshot = LatestMealStore.snapshot()
        return MealsWidgetEntry(
            date: Date(),
            snapshot: snapshot,
            image: LatestMealStore.loadLatestImage()
        )
    }
}

/// Lets the widget pick up a new photographed meal without the app running.
/// Falls back silently to the App Group snapshot the app last wrote.
enum WidgetCloudKitRefresh {
    static func run() async {
        guard RuntimeConfig.widgetCloudKitEnabled, PairingStore.load().isPaired else { return }
        let ownerName = PairingStore.load().ownerName
        do {
            let feed = try await AsyncTimeout.run(seconds: 20) {
                try await MealCloudKitFetcher().fetchFeed(ownerName: ownerName, photoDownloadLimit: 0)
            }
            let pairing = PairingStore.load()
            guard pairing.isPaired, let meal = feed.latestPhotographedMeal, let photo = feed.latestPhotoData else { return }
            LatestMealStore.saveSnapshot(latestPhotographedMeal: meal, latestPhoto: photo, pairing: pairing)
        } catch {
            MealsLog.cloudKit.error("Widget CloudKit refresh failed: \(error.localizedDescription, privacy: .public)")
        }
    }
}

enum MealsTimelineSchedule {
    static var reloadInterval: TimeInterval {
        RuntimeConfig.widgetCloudKitEnabled ? 30 * 60 : 60 * 60
    }

    static let horizon: TimeInterval = 24 * 3600

    /// Entries only where `RelativeTimestamp.widgetLabel` would change, covering ~24h.
    static func entryDates(for meal: Meal?, from now: Date) -> [Date] {
        guard let meal else { return [now] }
        let end = now.addingTimeInterval(horizon)
        let taken = meal.photographedAt
        var dates: [Date] = [now, taken.addingTimeInterval(60), taken.addingTimeInterval(3600), taken.addingTimeInterval(48 * 3600)]
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

struct MealsWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: WidgetKind.latestMeal, provider: MealsTimelineProvider()) { entry in
            MealsWidgetEntryView(entry: entry)
        }
        .configurationDisplayName("Latest meal")
        .description("The most recent photographed meal, with its name and time. No glucose data.")
        .supportedFamilies([
            .systemSmall,
            .systemMedium,
            .accessoryCircular,
            .accessoryRectangular,
            .accessoryInline
        ])
    }
}

struct MealsWidgetEntryView: View {
    @Environment(\.widgetFamily) private var family
    var entry: MealsWidgetEntry

    var body: some View {
        switch family {
        case .systemSmall:
            smallHome
        case .systemMedium:
            mediumHome
        case .accessoryRectangular:
            lockRectangular
        case .accessoryCircular:
            lockCircular
        case .accessoryInline:
            lockInline
        default:
            mediumHome
        }
    }

    private var smallHome: some View {
        ZStack(alignment: .bottomLeading) {
            backgroundPhoto
            LinearGradient(
                colors: [.black.opacity(0.05), .black.opacity(0.62)],
                startPoint: .top,
                endPoint: .bottom
            )
            VStack(alignment: .leading, spacing: 2) {
                Text(titleText)
                    .font(.system(.headline, design: .serif))
                    .foregroundStyle(.white)
                    .lineLimit(2)
                Text(timeText)
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.9))
            }
            .padding(12)
        }
        .clipped()
        .containerBackground(for: .widget) {
            Palette.paper
        }
    }

    private var mediumHome: some View {
        HStack(spacing: 14) {
            backgroundPhoto
                .frame(width: 118)
                .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
            VStack(alignment: .leading, spacing: 6) {
                Text("Latest meal")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Palette.muted)
                Text(titleText)
                    .font(.system(.title3, design: .serif).weight(.medium))
                    .foregroundStyle(Palette.ink)
                    .lineLimit(3)
                Text(timeText)
                    .font(.subheadline)
                    .foregroundStyle(Palette.muted)
                if let owner = entry.snapshot.ownerName, entry.snapshot.meal != nil {
                    Text(owner)
                        .font(.caption)
                        .foregroundStyle(Palette.sage)
                }
            }
            Spacer(minLength: 0)
        }
        .containerBackground(for: .widget) {
            Palette.paper
        }
    }

    private var lockRectangular: some View {
        HStack(spacing: 8) {
            if let image = entry.image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
                    .frame(width: 36, height: 36)
                    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            } else {
                Image(systemName: emptySymbol)
                    .font(.title3)
            }
            VStack(alignment: .leading, spacing: 1) {
                Text(titleText)
                    .font(.headline)
                    .lineLimit(1)
                Text(timeText)
                    .font(.caption)
            }
        }
        .containerBackground(for: .widget) {
            AccessoryWidgetBackground()
        }
    }

    private var lockCircular: some View {
        ZStack {
            AccessoryWidgetBackground()
            if let image = entry.image, entry.snapshot.meal != nil {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
                    .clipShape(Circle())
            } else {
                Image(systemName: emptySymbol)
                    .font(.title3)
            }
        }
        .clipShape(Circle())
        .containerBackground(for: .widget) {
            AccessoryWidgetBackground()
        }
    }

    private var lockInline: some View {
        Text("\(titleText) · \(timeText)")
            .containerBackground(for: .widget) {
                Color.clear
            }
    }

    @ViewBuilder
    private var backgroundPhoto: some View {
        if let image = entry.image, entry.snapshot.meal != nil {
            Image(uiImage: image)
                .resizable()
                .scaledToFill()
        } else {
            ZStack {
                Palette.terracotta.opacity(0.14)
                Image(systemName: emptySymbol)
                    .font(.title)
                    .foregroundStyle(Palette.terracotta)
            }
        }
    }

    private var titleText: String {
        if let meal = entry.snapshot.meal {
            return meal.title
        }
        return entry.snapshot.isPaired ? "No meals yet" : "Not paired"
    }

    private var timeText: String {
        if let meal = entry.snapshot.meal {
            return RelativeTimestamp.widgetLabel(from: meal.photographedAt, now: entry.date)
        }
        return entry.snapshot.isPaired ? "Waiting" : "Open Meals to pair"
    }

    private var emptySymbol: String {
        entry.snapshot.isPaired ? "camera" : "fork.knife"
    }
}

@main
struct MealsWidgetBundle: WidgetBundle {
    var body: some Widget {
        MealsWidget()
    }
}

#Preview("Small empty", as: .systemSmall) {
    MealsWidget()
} timeline: {
    MealsWidgetEntry(date: .now, snapshot: .empty, image: nil)
}

#Preview("Medium empty", as: .systemMedium) {
    MealsWidget()
} timeline: {
    MealsWidgetEntry(date: .now, snapshot: .empty, image: nil)
}
