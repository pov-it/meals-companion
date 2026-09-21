# Meals Companion

A **private**, meal-only iPhone app + Home Screen (and Lock Screen) widget so Mayee can see Marijn’s photographed meals.

This is not Trio. It does not show glucose, IOB, COB, insulin, carbs, or pump data. Trio does not need to be installed on her phone.

Notifications default **off**. The widget is the point.

## What you get

| Target | Role |
| --- | --- |
| `MealsCompanion` | SwiftUI app: pairing, latest meal, short history, empty states, settings |
| `MealsWidget` | WidgetKit extension: latest photo + name + time |
| `MealsKit/` | Shared models + App Group snapshot used by app and widget |

Open `MealsCompanion.xcodeproj` on a Mac with Xcode 15.4+ (iOS 17 SDK).

## Identifiers (TEAM / BUNDLE)

All IDs are derived from `DEVELOPMENT_TEAM` in xcconfig. Edit **one** placeholder:

```xcconfig
// Config/Team.xcconfig
DEVELOPMENT_TEAM = TEAMID
```

`Config/Shared.xcconfig` then produces:

| Setting | Pattern |
| --- | --- |
| App bundle ID | `org.pov-it.$(DEVELOPMENT_TEAM).meals` |
| Widget bundle ID | `org.pov-it.$(DEVELOPMENT_TEAM).meals.widget` |
| App Group | `group.org.pov-it.$(DEVELOPMENT_TEAM).meals` |
| CloudKit container | `iCloud.org.pov-it.$(DEVELOPMENT_TEAM).meals` |

Replace `TEAMID` with the real 10-character Team ID **before** creating App IDs, App Groups, or the CloudKit container. Changing the team later changes every identifier.

Optional: copy `Config/Team.xcconfig` to `Config/Team.local.xcconfig` (gitignored) if you do not want a team id in git. You would then `#include "Team.local.xcconfig"` from `Shared.xcconfig` instead.

Signing uses the same Apple Developer team that will sign later. This repo contains **no certificates, no API keys, no secrets**.

## Pairing (CloudKit share)

Transport is **CloudKit shared database + `CKShare`**, not HTTPS. No companion server. Both phones must be signed into iCloud.

1. Marijn’s **Trio** (publisher, not this repo) creates a custom zone `MealsZone`, a root `MealFeed` record, and a `CKShare` for that zone / root.
2. He invites Mayee’s Apple ID, or sends her the iCloud share URL (Messages is fine).
3. On her phone, in **this** app:
   - opening the share from Messages/Mail should hit the accept-share stub (`userDidAcceptCloudKitShareWith` + paste-link screen), or
   - she pastes `https://www.icloud.com/share/…` on the pairing screen and taps **Accept share**.
4. The app reads `Meal` records from the **shared** CloudKit database, writes the latest photo/name/time into the App Group, and reloads the widget.

Trio does not need to be on her phone. She must sign in to iCloud.

### Record contract (publisher must match)

Container: `iCloud.org.pov-it.$(DEVELOPMENT_TEAM).meals`  
Zone: `MealsZone` (private DB on Marijn’s side, shared via `CKShare`)

**`MealFeed`** (one root record, shared)

| Field | Type | Notes |
| --- | --- | --- |
| `ownerDisplayName` | String | e.g. `Marijn` |

**`Meal`**

| Field | Type | Notes |
| --- | --- | --- |
| `title` | String | Meal name |
| `photographedAt` | Date | When the photo was taken |
| `photo` | CKAsset | JPEG/HEIC |
| `ownerDisplayName` | String | Optional; falls back to the feed name |

This app **never** displays `glucose`, `sgv`, `iob`, `cob`, `insulin`, `carbs`, `pump`, or Nightscout fields, even if a publisher writes them. Do not put those fields on these records.

## Widget

After pairing:

1. Long-press the Home Screen → **Edit** → **Add Widget**
2. Search **Meals**
3. Add small or medium
4. Lock Screen: Edit Lock Screen → add a widget → **Meals** (rectangular / circular / inline)

Empty states:

- Not paired: “Not paired”
- Paired, no meals yet: “No meals yet”

The widget reads a local App Group snapshot. It does not talk to CloudKit itself. The host app refreshes that snapshot when it becomes active and when a **silent** CloudKit subscription fires (`content-available`). WidgetKit also rebuilds the timeline about every 15 minutes so relative times do not go stale. Apple throttles widgets; updates are not instant.

## Notifications

User-visible notifications default **OFF**. The app does not request notification permission unless she enables **Notify when a meal arrives** in Settings.

Silent CloudKit pushes (no banner, no sound) are used only to refresh the widget. That is not the same as spamming lock-screen alerts.

## Privacy

- Meal photo, meal name, timestamp. Nothing else.
- Data lives in the couple’s iCloud share (Apple IDs), not on a developer server.
- No Nightscout, no Libre UI, no analytics SDK, no tracking (`NSPrivacyTracking` is false).
- App Store category is **Lifestyle**, not Medical.
- Unpairing this phone deletes the local cache and widget snapshot. It does not delete Marijn’s originals.

## TestFlight — add Mayee as an *internal* tester on **this app only**

Do **not** add her to Trio’s TestFlight group. Create a separate App Store Connect **app record** for Meals Companion (this bundle ID). Trio stays a different app.

1. In [App Store Connect](https://appstoreconnect.apple.com) → **Users and Access** → add Mayee with her Apple ID email.
2. Give her a role that can install internal TestFlight builds (e.g. **Marketing** or **App Manager**).
3. **Limit her app access** to **Meals Companion only**. Uncheck Trio and every other app. This is the step that keeps Trio private.
4. Open the **Meals Companion** app record (not Trio) → **TestFlight** → **Internal Testing**.
5. Create a group (e.g. `Mayee`) and add her.
6. Archive **this** project in Xcode (Release, real `DEVELOPMENT_TEAM`) and upload the build. Bump `CURRENT_PROJECT_VERSION` in `Config/Shared.xcconfig` for each upload. Wait for processing.
7. She accepts the App Store Connect user invite, installs **TestFlight**, and installs **Meals** — not Trio.

Internal testers are App Store Connect users. If you skip “limit app access”, she may see Trio in ASC. External TestFlight is a different path (no ASC user); this README follows the requested internal-tester flow.

## Apple / CloudKit setup Marijn must finish

This repo is structural. It will not talk to iCloud until the Apple-side work exists. None of that can be done from git.

1. **Paid Apple Developer Program** on the same team that will sign Trio and this app.
2. Set `DEVELOPMENT_TEAM` in `Config/Team.xcconfig`.
3. Developer portal → Identifiers:
   - App ID for `org.pov-it.<TEAM>.meals` with App Groups, iCloud (CloudKit), Push Notifications.
   - App ID for `org.pov-it.<TEAM>.meals.widget` with the same App Group (widget does not need CloudKit).
   - App Group `group.org.pov-it.<TEAM>.meals`.
   - CloudKit container `iCloud.org.pov-it.<TEAM>.meals`.
4. Xcode: select the team, let it regenerate capabilities if it offers to. Confirm entitlements still use the xcconfig variables.
5. **CloudKit Dashboard**: create the container if needed, add record types `Meal` and `MealFeed` with the fields above, mark `Meal` as **queryable**, create `MealsZone` (or let Trio create it), and **Deploy Schema to Production** before TestFlight. Development-environment CloudKit does not serve TestFlight/App Store builds.
6. **Trio publisher work (not in this repo):** add this meals container as a *second* CloudKit container on Trio (leave glucose in Trio’s existing container), write only `Meal` / `MealFeed` records, create the `CKShare`, invite Mayee. Until that ships, this app can pair in UI form only.
7. Upload a TestFlight build of **this** app.
8. On her phone: iCloud signed in, install Meals, accept the share, add the widget.

Honest gaps:

- Share acceptance from Messages depends on Apple wiring `CKSharingSupported` + the CloudKit container to this bundle; paste-link is the reliable stub if the system handoff misroutes.
- Widget freshness is best-effort. Silent pushes require Push Notifications on the App ID and a Production CloudKit schema. Apple still throttles WidgetKit.
- There is no HTTPS fallback in this project. If Trio cannot publish to this CloudKit container, pairing will not receive meals.
- Simulator CloudKit sharing is limited; use two devices (or DEBUG **Load sample meal** in Settings to preview the widget without iCloud).

## Local DEBUG

Debug Settings includes **Load sample meal**, which writes a placeholder plate into the App Group so the widget can be laid out without a live share. It is compiled out of Release.

## Layout

```
Config/                  Team, bundle, App Group, CloudKit IDs
MealsKit/                Shared meal snapshot + theme
MealsCompanion/          SwiftUI app + CloudKit accept/fetch
MealsWidget/             WidgetKit extension
MealsCompanion.xcodeproj
```
