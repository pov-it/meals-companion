import SwiftUI

struct MealFeedView: View {
    @Environment(MealFeedController.self) private var feed
    @State private var selectedMeal: Meal?

    var body: some View {
        Group {
            if feed.meals.isEmpty {
                EmptyMealsView()
            } else {
                mealList
            }
        }
        .refreshable {
            await feed.refresh()
        }
        .sheet(item: $selectedMeal) { meal in
            MealDetailView(meal: meal, image: LatestMealStore.photo(for: meal))
        }
    }

    private var mealList: some View {
        ScrollView {
            VStack(spacing: 20) {
                if let hero = feed.meals.first {
                    Button {
                        selectedMeal = hero
                    } label: {
                        MealHeroCard(meal: hero, image: feed.latestPhoto ?? LatestMealStore.photo(for: hero))
                    }
                    .buttonStyle(.plain)
                }
                if feed.meals.count > 1 {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Earlier")
                            .font(.headline)
                            .foregroundStyle(Palette.ink)
                        ForEach(feed.meals.dropFirst()) { meal in
                            Button {
                                selectedMeal = meal
                            } label: {
                                MealRow(meal: meal, image: LatestMealStore.photo(for: meal))
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
            .padding(20)
        }
        .mealsScreenBackground()
    }
}

struct EmptyMealsView: View {
    @Environment(MealFeedController.self) private var feed

    var body: some View {
        VStack(spacing: 18) {
            Spacer()
            ZStack {
                Circle()
                    .stroke(Palette.muted.opacity(0.4), style: StrokeStyle(lineWidth: 2, dash: [6, 6]))
                    .frame(width: 132, height: 132)
                Image(systemName: "camera")
                    .font(.system(size: 34))
                    .foregroundStyle(Palette.sage)
            }
            Text("No meals yet")
                .font(TypeStyle.mealTitle)
                .foregroundStyle(Palette.ink)
            Text("Paired and waiting. When a meal is photographed, it will appear here and on the Home Screen widget.")
                .font(TypeStyle.caption)
                .foregroundStyle(Palette.muted)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 28)
            if feed.isRefreshing {
                ProgressView("Checking the share…")
                    .tint(Palette.terracotta)
            }
            if let lastError = feed.lastError {
                Text(lastError)
                    .font(.footnote)
                    .foregroundStyle(Palette.terracotta)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal)
            }
            Spacer()
        }
        .frame(maxWidth: .infinity)
        .mealsScreenBackground()
    }
}

struct MealHeroCard: View {
    let meal: Meal
    let image: UIImage?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            mealImage
                .frame(maxWidth: .infinity)
                .frame(height: 320)
                .clipShape(RoundedRectangle(cornerRadius: 28, style: .continuous))
            Text(meal.title)
                .font(TypeStyle.mealTitle)
                .foregroundStyle(Palette.ink)
            Text(RelativeTimestamp.feedLabel(from: meal.photographedAt))
                .font(TypeStyle.caption)
                .foregroundStyle(Palette.muted)
            if let ownerName = meal.ownerName {
                Text(ownerName)
                    .font(.footnote.weight(.medium))
                    .foregroundStyle(Palette.sage)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(meal.title), \(RelativeTimestamp.feedLabel(from: meal.photographedAt))")
    }

    @ViewBuilder
    private var mealImage: some View {
        if let image {
            Image(uiImage: image)
                .resizable()
                .scaledToFill()
        } else {
            ZStack {
                Palette.terracotta.opacity(0.12)
                Image(systemName: "photo")
                    .font(.largeTitle)
                    .foregroundStyle(Palette.muted)
            }
        }
    }
}

struct MealRow: View {
    let meal: Meal
    let image: UIImage?

    var body: some View {
        HStack(spacing: 14) {
            Group {
                if let image {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                } else {
                    Palette.terracotta.opacity(0.12)
                }
            }
            .frame(width: 72, height: 72)
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            VStack(alignment: .leading, spacing: 4) {
                Text(meal.title)
                    .font(.headline)
                    .foregroundStyle(Palette.ink)
                Text(RelativeTimestamp.feedLabel(from: meal.photographedAt))
                    .font(TypeStyle.caption)
                    .foregroundStyle(Palette.muted)
            }
            Spacer()
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(Color.white.opacity(0.55))
        )
    }
}

struct MealDetailView: View {
    let meal: Meal
    let image: UIImage?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    MealHeroCard(meal: meal, image: image)
                }
                .padding(20)
            }
            .mealsScreenBackground()
            .navigationTitle(meal.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                }
            }
        }
        .tint(Palette.terracotta)
    }
}

#Preview("Empty") {
    EmptyMealsView()
        .environment(MealFeedController.shared)
}
