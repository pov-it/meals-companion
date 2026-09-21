import SwiftUI

struct RootView: View {
    @Environment(MealFeedController.self) private var feed
    @State private var showingSettings = false

    var body: some View {
        NavigationStack {
            Group {
                if feed.pairing.isPaired {
                    MealFeedView()
                } else {
                    PairingView()
                }
            }
            .navigationTitle("Meals")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        showingSettings = true
                    } label: {
                        Image(systemName: "gearshape")
                    }
                    .accessibilityLabel("Settings")
                }
            }
            .sheet(isPresented: $showingSettings) {
                SettingsView()
            }
        }
        .tint(Palette.terracotta)
        .mealsScreenBackground()
    }
}

#Preview {
    RootView()
        .environment(MealFeedController.shared)
}
