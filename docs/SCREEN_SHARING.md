# Live screen preview on iPhone XR

This is a visible, user-started ReplayKit broadcast for iOS 16–18. It sends up to
two JPEG frames per second, scaled to fit 720 × 1280, with one upload in flight.
It is a live preview, not full-motion video or remote control. Microphone and
app audio from ReplayKit are ignored; the existing audio monitor is separate.

## Setup

1. Run the ingest server with `INGEST_TOKEN` set to a strong private value.
   Use HTTPS when connecting across the internet. The screen endpoints refuse
   operation when the server has no token configured.
2. Sign the main app and `ScreenBroadcast` extension with the same development
   team. Register an App Group and set `NEXUS_APP_GROUP` in `project.yml` to its
   identifier. Both targets use `Resources/ScreenSharing.entitlements`.
3. If changing bundle identifiers, keep the extension ID equal to the main app
   ID plus `.screen`; this is the ID the system broadcast picker selects.
4. Install the signed app on the XR. In Settings, save the reachable server URL
   and ingest token. `localhost` on the iPhone means the iPhone, not your computer.
5. Accept the app’s consent screen. Choose **Enable screen sharing**, tap the
   system broadcast button, then **Start Broadcast** on the iPhone.
6. Open the server dashboard, select the device, enter the same token, and choose
   **View screen**. The token stays in page memory and is sent in an Authorization
   header, never in a URL or browser storage.

The on-device screen sharing control is separate from the audio recording
button. Use **Disable screen sharing** or the iOS recording indicator to end it.
Revoking consent and saving changed settings disable screen sharing too.
Disconnecting the dashboard viewer does not stop the iPhone’s broadcast.

## Consent and interruptions

An initial permission grant does not permit unattended future whole-screen
broadcasts. Each new broadcast starts through the iPhone’s system UI. ReplayKit
can show other apps while a broadcast is active. Protected content may be blank;
phone locking, calls, network changes, or system resource limits may interrupt
or end sharing. There is no silent restart or bypass of these controls.

The broadcast config uses complete file protection, so locking the device can
make it unavailable and end the broadcast. The extension checks enabled state
every second. The dashboard marks frames older than three seconds as waiting
and clears them after ten seconds. Frames are held only in server memory, at
most one 1 MiB frame per device, with a maximum of 32 devices. No screen history
is written to the media archive. An interrupted extension may not deliver its
stop request; frame expiry still removes it from the live view.

## Validation required on a physical XR

- Confirm the broadcast picker lists **Self-Monitor Screen** and signing allows
  the app and extension to access the same App Group.
- Start a broadcast, move to another app, rotate the phone, and verify actual
  changing content on the dashboard.
- Stop through the system indicator, disable sharing, revoke consent, and lock
  the phone; ensure the viewer becomes offline without displaying an old live frame.
- Disconnect and restore the network; check bounded memory and resumption or
  visible error state. Test under Low Power Mode and with a prolonged session.

Server integration tests use synthetic JPEG bytes; they are not evidence of a
physical iPhone broadcast. Simulator tests validate lifecycle and upload logic;
hardware capture, signing, and sustained XR performance require the device.

References: [Apple ReplayKit security](https://support.apple.com/en-gb/guide/security/seca5fc039dd/web),
[ReplayKit](https://developer.apple.com/documentation/replaykit),
[sample handler](https://developer.apple.com/documentation/replaykit/rpbroadcastsamplehandler).
