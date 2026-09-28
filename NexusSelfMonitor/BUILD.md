# Building Nexus Self-Monitor (iOS)

The Nexus Self-Monitor app is built with native Swift 5 and SwiftUI targeting iOS 16.0+. The repository uses **XcodeGen** (`project.yml`) to generate a reproducible `.xcodeproj` without checking in bulky binary project metadata.

The app now includes the `ScreenBroadcast` ReplayKit extension and a native
`NexusSelfMonitorTests` target. See [screen sharing setup](../docs/SCREEN_SHARING.md)
for signing and on-device broadcast requirements. An unsigned IPA is a build
artifact, not an installable app: both targets must be signed with matching App
Group entitlements before installing on the iPhone XR.

Run native regressions on an available simulator after generating the project:

```bash
xcodebuild test -project NexusSelfMonitor.xcodeproj -scheme NexusSelfMonitor \
  -destination 'platform=iOS Simulator,name=iPhone 15' CODE_SIGNING_ALLOWED=NO
```

Replace the simulator name with one installed in Xcode. CI selects an available
iPhone automatically and uploads its `.xcresult` along with the unsigned IPA.

---

## Option 1: Build on macOS with Xcode (Local Development)

### Prerequisites
1. A Mac running macOS 13 (Ventura) or macOS 14 (Sonoma) or newer.
2. Xcode 15 or 16 installed from the Mac App Store.
3. [XcodeGen](https://github.com/yonaskolb/XcodeGen) installed via Homebrew:
   ```bash
   brew install xcodegen
   ```

### Step 1: Generate the Xcode Project
Navigate to the `NexusSelfMonitor` folder:
```bash
cd nexus-ios/NexusSelfMonitor
xcodegen generate
```
This generates `NexusSelfMonitor.xcodeproj`.

### Step 2: Open & Configure Signing in Xcode
```bash
open NexusSelfMonitor.xcodeproj
```
1. Select the `NexusSelfMonitor` root project node in the navigator.
2. Select the `NexusSelfMonitor` Target -> **Signing & Capabilities**.
3. Under **Signing**:
   - Check **Automatically manage signing**.
   - Under **Team**, select your Apple ID (Personal Team works for free sideloading to your own iPhone).
   - If bundle ID conflict occurs, adjust the Bundle Identifier (e.g. `com.yourname.selfmonitor.app`).

### Step 3: Run on Simulator or Physical iPhone
- **Simulator**: Choose any iPhone simulator (e.g., iPhone 15 / 16) from the device dropdown and press **Cmd + R**.
- **Physical Device**: Connect your iPhone via USB, trust the computer, select your iPhone in the device dropdown, and click **Run**. (Note: If this is your first time sideloading with a free Apple Developer account, go to iPhone **Settings > Privacy & Security > Developer Mode** and enable it).

---

## Option 2: Build via Terminal Command Line (macOS CLI)

If you prefer building headless from terminal or scripts on a Mac:

### 1. Build for Simulator:
```bash
cd nexus-ios/NexusSelfMonitor
xcodegen generate

xcodebuild build \
  -project NexusSelfMonitor.xcodeproj \
  -scheme NexusSelfMonitor \
  -destination 'generic/platform=iOS Simulator' \
  -configuration Release \
  CODE_SIGNING_ALLOWED=NO
```

### 2. Build and Package an Unsigned `.ipa`:
```bash
xcodebuild build \
  -project NexusSelfMonitor.xcodeproj \
  -scheme NexusSelfMonitor \
  -destination 'generic/platform=iOS' \
  -configuration Release \
  CODE_SIGNING_ALLOWED=NO \
  CODE_SIGN_IDENTITY="" \
  SYMROOT=build

mkdir -p build/Payload
cp -r build/Release-iphoneos/NexusSelfMonitor.app build/Payload/
cd build && zip -r NexusSelfMonitor-unsigned.ipa Payload
```

---

## Option 3: Build from Linux via GitHub Actions (Cloud CI)

Because Apple's iOS SDKs (`UIKit`, `SwiftUI`, `AVFoundation`, `CoreLocation`, `CoreMotion`) are proprietary to Apple's Darwin Darwin/macOS operating system, native iOS binaries cannot be compiled on standard Linux kernels without a macOS runner.

A turnkey GitHub Actions workflow is provided at:
`.github/workflows/build-ios.yml`

### How to use:
1. Push this repository to GitHub (public or private repo):
   ```bash
   git init
   git add .
   git commit -m "Initial commit"
   git remote add origin https://github.com/your-username/nexus-ios.git
   git push -u origin main
   ```
2. In your GitHub repository, navigate to the **Actions** tab.
3. Select the **Build iOS App** workflow and run it (or let it run on push).
4. When finished, download the **`NexusSelfMonitor-unsigned-ipa`** build artifact.

### Sideloading the IPA onto your iPhone:
You can sign and install the resulting `.ipa` directly to your iPhone using any of the following tools:
- **AltStore / AltServer** (Mac & Windows): Free sideloading via personal Apple ID.
- **Sideloadly** (Mac & Windows): Simple drag-and-drop IPA installer.
- **TrollStore** (if on supported iOS version): Direct on-device installation.
- **iLoader** (on-device IPA installer): sign & install the unsigned IPA with your own certificate.

---

## Hiding the app on a test device

Test-device builds ship an **invisible Home Screen presence** so the app does not
advertise itself during training runs:

- `Resources/Assets.xcassets/AppIcon.appiconset/AppIcon1024.png` is a fully
  transparent 1024×1024 icon (selected via `ASSETCATALOG_COMPILER_APPICON_NAME`
  in `project.yml`), so the wallpaper shows through the icon slot.
- `CFBundleDisplayName` in `Resources/Info.plist` is a single zero-width space
  (`U+200B`), so no name renders under the icon (or in Settings / app switcher).
- The `ScreenBroadcast` extension display name in
  `BroadcastExtension/Info.plist` is blanked the same way, so the app does not
  appear by name in the system screen-recorder/broadcast picker.

The app remains reachable via Spotlight search (type nothing — swipe down on the
Home Screen and pick it from suggestions) or App Library, and iOS may still show
it in Settings → General → iPhone Storage.

To make it visible again, revert `CFBundleDisplayName` to a real name (e.g.
`Self-Monitor`) and either delete the asset catalog setting
(`ASSETCATALOG_COMPILER_APPICON_NAME`) or replace `AppIcon1024.png` with a real
icon, then rebuild and reinstall.

Device-side alternative (iOS 18+, no rebuild): touch and hold the app icon →
**Remove App** → **Hide App**; the app moves to the Hidden folder in App Library
behind Face ID/passcode.

Notes:

- A transparent icon is fine for sideloaded IPAs; App Store validation would
  reject it (missing required icon artwork / alpha channel), which is out of
  scope for test builds.
- With Home Screen icon tinting/dark mode enabled (iOS 18+), a tile may still be
  faintly visible; use the default icon appearance for best invisibility.

### Verifying the invisible build

`scripts/verify_hidden_app.py` (stdlib-only Python 3, so it runs on the Linux dev
box and on the CI runners alike) enforces the contract above and exits non-zero on
any regression:

```bash
python3 scripts/verify_hidden_app.py                                            # repository sources
python3 scripts/verify_hidden_app.py --app build/Release-iphoneos/NexusSelfMonitor.app
python3 scripts/verify_hidden_app.py --app build/NexusSelfMonitor-unsigned.ipa
```

## Auto-start & server configuration

The app opens and keeps a monitoring session running **without any taps**:

- `AppModel` owns a single session engine: `reconcile(_:)` funnels every trigger
  (app launch, foreground, view appearance, consent grant, settings save, retry
  expiry, and a 15-second health tick) through one pure decision,
  `autoRunDecision()`, which starts a session when *consent is granted* AND
  *Auto-start is enabled* AND *the app is configured* (valid server URL + ingest
  token).
- Transient failures (offline, throttled, 5xx, connection loss) retry on a
  bounded ladder — 2s → 5s → 15s → 60s (cap). Configuration and authorisation
  failures never spin: the status card reports exactly what is missing.
- An operator **Stop** wins for the rest of that process run (`operatorPaused`
  latch); a relaunch — e.g. by `scripts/phone-autostart-daemon.sh` — resumes
  automatically because the latch lives only in process memory.
- Consent remains a hard gate: without it the app shows `ConsentView` and never
  records, and `Settings.autoStartEnabled` can turn the whole behaviour off.

### Injecting the server URL and token

`Settings` reads `NexusServerURL` / `NexusIngestToken` from Info.plist, which
XcodeGen substitutes from the same-named build settings declared in
`project.yml`. Provide them **at build time** (never commit them):

```bash
xcodebuild build -project NexusSelfMonitor.xcodeproj -scheme NexusSelfMonitor \
  -destination 'generic/platform=iOS' -configuration Release \
  NEXUS_SERVER_URL=http://192.168.1.53:8787 NEXUS_INGEST_TOKEN=<token>
```

CI injects the same two build settings from the repository secrets
`NEXUS_SERVER_URL` / `NEXUS_INGEST_TOKEN`. A build without them still works:
enter the values once in Settings → the engine takes over from there. Legacy
stored settings decode losslessly on upgrade
(`SettingsTests.testLegacyJSONWithoutAutoStartKeyDecodesLosslessly`), so a
reinstalled app never loses its configuration to a defaults fallback.

### One-Time Start & Stealth Mode
- **Initial Start:** On the first launch after install, the operator clicks **"Start"** once.
- **Auto-Dismiss:** Immediately upon starting, the app programmatically suspends itself to the background (`suspendToBackground`), returning the iPhone to the Home Screen so the monitoring window does not stay open.
- **Stealth Blank Screen on Reopen:** Tapping or reopening the app displays a completely blank black screen (`StealthView`) with no dashboard or controls. Tapping the blank screen immediately suspends back to the Home Screen.
- **Management:** Sessions, streaming data, and logs are observed and managed remotely from the server dashboard.

**Verifying operation:** install the build, open the app, tap "Start" once, confirm the app returns to the Home Screen, and verify that audio segments flow into `server/data/<deviceId>/`. Re-opening the app presents a blank black screen.

It asserts that both display names contain no visible glyph, that the `AppIcon`
catalog entry is a fully transparent 8-bit RGBA PNG, that `project.yml` wires that
catalog into the app target, and - for a built artifact - that the compiled icon
artwork and the screen-broadcast extension are actually inside the bundle.

`Tests/InvisibleAppTests.swift` asserts the display-name and icon-artwork
properties at runtime from inside the built bundle. Both the script and the native
tests run in the `Build iOS App` workflow; add the script to any local pre-push
hook to catch a reverted display name before it reaches the device.

