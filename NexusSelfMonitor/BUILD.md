# Building Nexus Self-Monitor (iOS)

The Nexus Self-Monitor app is built with native Swift 5 and SwiftUI targeting iOS 16.0+. The repository uses **XcodeGen** (`project.yml`) to generate a reproducible `.xcodeproj` without checking in bulky binary project metadata.

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
