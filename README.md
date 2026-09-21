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

All IDs are derived from `DEVELOPMENT_TEAM` in `Config/Team.xcconfig`. That file is set to Marijn’s team:

```xcconfig
DEVELOPMENT_TEAM = Q6QCL8J6FN
```

`Config/Shared.xcconfig` expands that to:

| Setting | Resolved value |
| --- | --- |
| App bundle ID | `org.pov-it.Q6QCL8J6FN.meals` |
| Widget bundle ID | `org.pov-it.Q6QCL8J6FN.meals.widget` |
| App Group | `group.org.pov-it.Q6QCL8J6FN.meals` |
| CloudKit container | `iCloud.org.pov-it.Q6QCL8J6FN.meals` |

Those identifiers already exist on the Apple Developer portal. Changing `DEVELOPMENT_TEAM` later would change every identifier.

Optional: copy `Config/Team.xcconfig` to `Config/Team.local.xcconfig` (gitignored) and switch `Shared.xcconfig` to `#include "Team.local.xcconfig"` if you do not want a team id in git.

This repo contains **no certificates, no API keys, no secrets**.

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

Container: `iCloud.org.pov-it.Q6QCL8J6FN.meals`  
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
6. Upload a build via **browser build** (below) or Xcode (Release, team `Q6QCL8J6FN`). CI bumps `CURRENT_PROJECT_VERSION` from the latest TestFlight build number; for manual Xcode uploads bump it in `Config/Shared.xcconfig`. Wait for processing.
7. She accepts the App Store Connect user invite, installs **TestFlight**, and installs **Meals** — not Trio.

Internal testers are App Store Connect users. If you skip “limit app access”, she may see Trio in ASC. External TestFlight is a different path (no ASC user); this README follows the requested internal-tester flow.

## Browser build / TestFlight (GitHub Actions — no Mac required)

Pattern copied from `pov-it/Trio` (`4. Build Trio`: `macos-26` + Fastlane + Match + App Store Connect API key). This repo has **no** glucose/Nightscout secrets.

### Secrets (same names as Trio)

Copy these from the Trio repo (or org) into **this** repo’s Actions secrets if they are not already available at org level:

| Secret | Purpose |
| --- | --- |
| `TEAMID` | 10-character Apple Team ID (injected into `Config/Team.xcconfig` at CI time; not committed) |
| `GH_PAT` | Classic PAT with `repo` (+ `workflow` preferred) to read/write `pov-it/Match-Secrets` |
| `MATCH_PASSWORD` | Match encryption password (same as Trio) |
| `FASTLANE_KEY_ID` | App Store Connect API key id |
| `FASTLANE_ISSUER_ID` | App Store Connect issuer id |
| `FASTLANE_KEY` | API key `.p8` contents (PEM body) |

Match storage is `https://github.com/<owner>/Match-Secrets.git` (same repo Trio uses). New Meals bundle IDs get **new provisioning profiles** on the existing distribution certificate — you do **not** need to nuke Trio’s certs.

### One-time Apple / Match setup (expected before first green build)

1. **App Store Connect app** for Meals Companion must exist with bundle ID `org.pov-it.<TEAMID>.meals` (create manually in ASC; the upload lane does not create the app record).
2. Run **Actions → “Add Meals Identifiers” → Run workflow** once. That lane:
   - registers App IDs `…meals` and `…meals.widget`, enables App Groups / iCloud (CloudKit) / Push, and wires App Group + CloudKit container onto those App IDs via ASC;
   - runs Match to create App Store profiles into `Match-Secrets`.
3. App Group `group.org.pov-it.<TEAMID>.meals` and CloudKit container `iCloud.org.pov-it.<TEAMID>.meals` must already exist in the Developer portal (created earlier). The identifiers lane links them onto the App IDs; if ASC refuses the relationship call, finish Configure on each App ID in the portal, then re-run Add Meals Identifiers (force-regenerates Match profiles).
4. **Enable the workflow files first** (one-time): this PR ships them under `ci/github-workflows/` because a GitHub OAuth token without the `workflow` scope cannot create `.github/workflows/*.yml`. With a PAT/`gh` auth that includes `workflow`:

```bash
mkdir -p .github/workflows
cp ci/github-workflows/*.yml .github/workflows/
git add .github/workflows && git commit -m "Enable browser-build workflows" && git push
```

Then run **Actions → “Build Meals Companion” → Run workflow**, or:

```bash
gh workflow run "Build Meals Companion" --repo pov-it/meals-companion --ref <branch>
```

`Config/Team.xcconfig` stays as `DEVELOPMENT_TEAM = TEAMID` in git. The Fastlane `build_meals` lane rewrites it in the runner workspace from the `TEAMID` secret.

### What fails on first run (honest)

| Failure | Cause | Fix |
| --- | --- | --- |
| Secrets empty / auth errors | Secrets not copied to this repo | Copy the six secrets from Trio / org |
| Match cannot find profiles | Meals App IDs never registered in Match | Run **Add Meals Identifiers** first |
| `latest_testflight_build_number` / upload errors about unknown app | No ASC app for `org.pov-it.<TEAMID>.meals` | Create the ASC app record with that exact bundle ID |
| Code sign / entitlement errors for App Groups or iCloud | Group/container not linked on the App ID | Finish portal linkage (see Apple setup below) |
| Upload succeeds but CloudKit dead on device | Schema still Development-only | Deploy CloudKit schema to Production |

This README does **not** claim a successful TestFlight upload has been run from CI yet — trigger the workflow after secrets + ASC app + identifiers exist.

## Apple / CloudKit setup Marijn must finish

This repo is structural. It will not talk to iCloud until the Apple-side work exists. None of that can be done from git.

1. **Paid Apple Developer Program** on team `Q6QCL8J6FN` (already set in `Config/Team.xcconfig`; CI also injects `TEAMID` secret over that line for the runner workspace).
2. Developer portal identifiers already exist for this team:
   - App ID `org.pov-it.Q6QCL8J6FN.meals` with App Groups, iCloud (CloudKit), Push Notifications.
   - App ID `org.pov-it.Q6QCL8J6FN.meals.widget` with the same App Group (widget does not need CloudKit).
   - App Group `group.org.pov-it.Q6QCL8J6FN.meals`.
   - CloudKit container `iCloud.org.pov-it.Q6QCL8J6FN.meals`.
3. Xcode: select team `Q6QCL8J6FN`, let it regenerate capabilities if it offers to. Confirm entitlements still use the xcconfig variables.
4. **CloudKit Dashboard**: add record types `Meal` and `MealFeed` with the fields above if they are not already there, mark `Meal` as **queryable**, create `MealsZone` (or let Trio create it), and **Deploy Schema to Production** before TestFlight. Development-environment CloudKit does not serve TestFlight/App Store builds.
5. **Trio publisher work (not in this repo):** add this meals container as a *second* CloudKit container on Trio (leave glucose in Trio’s existing container), write only `Meal` / `MealFeed` records, create the `CKShare`, invite Mayee. Until that ships, this app can pair in UI form only.
6. Upload a TestFlight build of **this** app via the browser-build workflow above, or Xcode.
7. On her phone: iCloud signed in, install Meals, accept the share, add the widget.

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
fastlane/                Match + build_meals + TestFlight upload
ci/github-workflows/     Build Meals Companion, Add Meals Identifiers (copy to .github/workflows/)
```
