import SwiftUI

struct SettingsView: View {
    @Environment(MealFeedController.self) private var feed
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section("Pairing") {
                    LabeledContent("Status", value: feed.pairing.isPaired ? "Paired" : "Not paired")
                    if let owner = feed.pairing.ownerName {
                        LabeledContent("From", value: owner)
                    }
                    if let accepted = feed.pairing.acceptedAt {
                        LabeledContent("Accepted", value: accepted.formatted(date: .abbreviated, time: .shortened))
                    }
                    if feed.pairing.isPaired {
                        Button("Stop receiving meals", role: .destructive) {
                            feed.unpair()
                            dismiss()
                        }
                    }
                }

                Section {
                    Toggle("Notify when a meal arrives", isOn: userVisibleBinding)
                } header: {
                    Text("Notifications")
                } footer: {
                    Text("Off by default. The Home Screen widget is the intended surface. Turning this on asks iOS for permission and may show a banner for new meals. Silent CloudKit pushes still refresh the widget without alerting you.")
                }

                Section("Privacy") {
                    Text("Meal photos, a name, and a timestamp only. No glucose, IOB, COB, insulin, carbs, or pump data. Photos live in the iCloud share between the two Apple IDs — not on a developer server, and not in Nightscout.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                Section("This device") {
                    LabeledContent("Version", value: versionLabel)
                    LabeledContent("iCloud", value: iCloudLabel)
                    LabeledContent("Container", value: RuntimeConfig.cloudKitContainerIdentifier)
                    LabeledContent("App Group", value: RuntimeConfig.appGroupIdentifier)
                    if feed.isUsingPlaceholderTeam {
                        Text("DEVELOPMENT_TEAM is still TEAMID. Replace it in Config/Team.xcconfig, enable the App Group and CloudKit container for that team, then rebuild.")
                            .font(.footnote)
                            .foregroundStyle(Palette.terracotta)
                    }
                }

#if DEBUG
                Section("Developer") {
                    Button("Load sample meal") {
                        feed.loadSampleMeal()
                        dismiss()
                    }
                }
#endif
            }
            .scrollContentBackground(.hidden)
            .background(Palette.paper)
            .navigationTitle("Settings")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .tint(Palette.terracotta)
    }

    private var userVisibleBinding: Binding<Bool> {
        Binding(
            get: { feed.userVisibleNotificationsEnabled },
            set: { enabled in
                Task { await feed.setUserVisibleNotifications(enabled) }
            }
        )
    }

    private var versionLabel: String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.1.0"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "1"
        return "\(version) (\(build))"
    }

    private var iCloudLabel: String {
        switch feed.iCloudStatus {
        case .available: return "Signed in"
        case .noAccount: return "Not signed in"
        case .restricted: return "Restricted"
        case .temporarilyUnavailable: return "Temporarily unavailable"
        case .couldNotDetermine: return "Unknown"
        case .none: return "Checking…"
        @unknown default: return "Unknown"
        }
    }
}
