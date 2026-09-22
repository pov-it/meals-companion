import SwiftUI

struct PairingView: View {
    @Environment(MealFeedController.self) private var feed
    @State private var linkText = ""

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                emptyPlate
                VStack(alignment: .leading, spacing: 10) {
                    Text("See photographed meals on a widget.")
                        .font(TypeStyle.largeMealTitle)
                        .foregroundStyle(Palette.ink)
                    Text("This app does not show glucose, insulin, or pump data. Pair with the publisher’s meal share, then add the Meals widget to your Home Screen.")
                        .font(TypeStyle.caption)
                        .foregroundStyle(Palette.muted)
                        .fixedSize(horizontal: false, vertical: true)
                }

                VStack(alignment: .leading, spacing: 12) {
                    Text("Paste the iCloud share link")
                        .font(.headline)
                        .foregroundStyle(Palette.ink)
                    TextField("https://www.icloud.com/share/…", text: $linkText)
                        .textInputAutocapitalization(.never)
                        .keyboardType(.URL)
                        .autocorrectionDisabled()
                        .padding(14)
                        .background(RoundedRectangle(cornerRadius: 14).fill(Color.white.opacity(0.72)))
                    Button {
                        guard let url = sanitizedURL else { return }
                        Task { await feed.acceptShare(from: url) }
                    } label: {
                        HStack {
                            if feed.isRefreshing {
                                ProgressView()
                                    .tint(.white)
                            }
                            Text(feed.isRefreshing ? "Accepting…" : "Accept share")
                                .font(.headline)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(sanitizedURL == nil || feed.isRefreshing)
                }

                pairingHints
            }
            .padding(24)
        }
        .mealsScreenBackground()
        .safeAreaInset(edge: .bottom) {
            if let lastError = feed.lastError {
                Text(lastError)
                    .font(.footnote)
                    .foregroundStyle(Palette.terracotta)
                    .padding()
                    .frame(maxWidth: .infinity)
                    .background(Palette.paper)
            }
        }
    }

    private var sanitizedURL: URL? {
        let trimmed = linkText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed), url.scheme != nil else { return nil }
        return url
    }

    private var emptyPlate: some View {
        ZStack {
            Circle()
                .stroke(Palette.terracotta.opacity(0.35), style: StrokeStyle(lineWidth: 3, dash: [7, 7]))
                .frame(width: 148, height: 148)
            Circle()
                .stroke(Palette.sage.opacity(0.4), lineWidth: 1)
                .frame(width: 108, height: 108)
            Image(systemName: "fork.knife")
                .font(.system(size: 36))
                .foregroundStyle(Palette.terracotta)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 12)
        .accessibilityHidden(true)
    }

    private var pairingHints: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Trio does not need to be installed on this phone.", systemImage: "iphone")
            Label("Opening the share from Messages also pairs this app.", systemImage: "bubble.left")
            Label("Notifications stay off. The widget is the point.", systemImage: "bell.slash")
            if feed.isUsingPlaceholderTeam {
                Label("Set DEVELOPMENT_TEAM in Config/Team.xcconfig before CloudKit will work.", systemImage: "wrench.and.screwdriver")
                    .foregroundStyle(Palette.terracotta)
            }
        }
        .font(TypeStyle.caption)
        .foregroundStyle(Palette.muted)
    }
}

#Preview {
    PairingView()
        .environment(MealFeedController.shared)
}
