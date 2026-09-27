# Repository map

Updated 2026-09-27. Scope: the standalone `nexus-ios` repository. Its sibling
Android/forensics applications and exported user data are outside this task.
All handwritten files in this repository were read during the initial sweep;
generated IPA output, Git internals, and runtime data were excluded.

## Entry points and wiring

- `NexusSelfMonitorApp` owns `AppModel`, routes scene phase changes and injects
  it into `RootView`. `RootView` chooses `ConsentView` or `MonitorView`.
- `AppModel` owns `Settings`, `IngestClient`, audio, camera, location, telemetry,
  `UploadQueue`, tracked upload tasks, and independent background task leases.
  Startup is single-flight and invalidated by Stop. Async handlers retain the
  originating session/client. A previous interrupted session never starts
  recording automatically.
- `AudioRecorderService` publishes level and recording state, emits completed
  AAC files, and manages interruptions and cancellable retries. Recorder identity
  checks reject stale callbacks.
- `CameraCaptureService` serializes session start/stop, rejects stale session and
  capture completions, and compresses JPEGs on a utility queue. Switching cameras
  retains the session’s sequence counter.
- `LocationService` tracks requested updates separately from granted permission.
  The first permission grant starts updates, and late grants after Stop do not.
- `DeviceTelemetryService` owns motion/altimeter/pedometer/battery subscriptions;
  pedometer callbacks hop to the main actor and session identity rejects old data.
- `IngestClient` is a URLSession actor. It encodes `Wire` requests, classifies HTTP
  failures, streams persisted retries from files, and logs actual stop failures.
- `UploadQueue` persists media metadata and files. The retry loop snapshots IDs,
  mutates current entries after suspension, and preserves concurrent enqueues.
  Stop cancels work without releasing its slot prematurely. In-flight files are
  protected from retention eviction.
- `DiagnosticsLogger` feeds the monitor badges and `DiagnosticsView`; it bounds
  log history and reuses its time formatter. `SettingsView` edits settings,
  retries queued files, revokes consent, and requests server deletion.
- `ScreenBroadcastView` exposes the real system broadcast picker.
  `BroadcastConfiguration` shares explicit enablement and configuration via a
  signed App Group. The separately embedded `SampleHandler` consumes ReplayKit
  frames, scales/compresses on its serial queue, and streams bounded live frames.
- `server/server.js` composes config, logger, Store, SSEHub, rate limiter, and
  router, and owns shutdown. Importing it does not bind a port.
- `server/src/router.js` handles session/location/media/telemetry/delete/health,
  authenticated live-screen routes, and static files. `util.js` validates
  coordinates and sanitizes legacy path segments.
- `Store` loads and persists session/media metadata, writes media files, and
  enforces retention. `SSEHub` maintains clients and a bounded replay list;
  `rateLimit.js` implements token buckets with an unref'd cleanup interval.
- `ScreenStream` maintains bounded, expiring, in-memory JPEG frames tied to
  active consented sessions. The existing ingest token protects screen reads
  and writes. `public/screen.js` polls one selected device without overlapping
  requests, uses conditional responses, and clears expired/stopped feeds.
- `public/index.html` is the dashboard entry point, uses Leaflet when available,
  subscribes to SSE, and dispatches device inventory to the screen viewer.

## Build and tests

`NexusSelfMonitor/project.yml` generates the main app, ReplayKit extension, and
XCTest bundle. Main and extension plists declare the shared App Group key and
local-network usage. Both use `Resources/ScreenSharing.entitlements`.
`.github/workflows/build-ios.yml` builds simulator/device binaries, runs XCTest,
packages an unsigned IPA, and separately runs server tests on Linux.

- Native tests: `UploadQueueTests` (concurrent enqueue, cancellation, failures,
  retention), `AppModelTests` (duplicate/canceled startup and consent),
  `SettingsTests` (URL validation), `IngestClientTests` (responses and file retry).
- Server tests: legacy smoke suite and `screen.test.js` (auth, streaming bytes,
  conditional GET, validation, stop/delete, expiry, bounds, late requests).
- Runtime dependencies: Apple frameworks; Node built-ins; Leaflet and map tiles
  loaded from external CDNs. There are no package-manager runtime dependencies.

## Known gaps and non-task findings

- No orphan modules or dangling imports identified. The unused logger cache was
  removed. Some legacy diagnostic helpers remain unused (`filterLevel`, etc.).
- Legacy dashboard/media reads remain open even when an ingest token is set;
  only the new screen feed requires read authentication. Full access-control
  redesign is outside this patch.
- Legacy queued uploads do not persist destination identity. Do not change
  servers while pending media must remain associated with the old server.
- Existing media ingestion is not idempotent; ambiguous network retries can
  produce duplicate archive index entries. Server media retention and deletion
  durability need a separate data-management pass.
- The screen preview is two frames/sec, not full-motion video. Physical XR
  signing, cross-app capture, interruptions, and sustained performance remain
  device validation requirements; see `SCREEN_SHARING.md`.

## Verification status

2026-09-27: zero-dependency npm restore passed; all 6 legacy server tests and 7
new screen tests passed locally. Native compiler/XcodeGen/SwiftLint are absent
on Linux. macOS CI build and native tests are pending for this change. No
physical iPhone is accessible through the local device tooling.
