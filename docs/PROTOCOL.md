# Nexus Self-Monitor — Wire Protocol (v1)

A deliberately small, transparent contract between the iOS app (client) and the
ingest server. There is nothing covert here: every request is client-initiated,
the server refuses data unless the client asserts consent, and all stored data
is enumerable and deletable through the API.

Base URL: `http://<host>:<port>` (default port `8787`). Use HTTPS in real use
(e.g. an ngrok/Cloudflare tunnel in front of the server).

## Auth (optional but recommended)
If the server is started with `INGEST_TOKEN` set, every `/api/v1/*` ingest call
must send `Authorization: Bearer <token>`. If unset, auth is skipped (local dev).

## Endpoints

### `GET /api/v1/health`
`200 {"ok":true,"uptimeSec":<n>,"devices":<n>}`

### `POST /api/v1/session`
Register or heartbeat a monitoring session.
Request JSON:
```json
{ "deviceId":"<stable-uuid>", "deviceName":"Paolo's iPhone",
  "consentAcknowledged": true, "startedAt": 1750000000000 }
```
`consentAcknowledged` MUST be `true` or the server responds `403`.
Response: `200 {"sessionId":"<uuid>"}`

### `POST /api/v1/location`
Request JSON:
```json
{ "deviceId":"...", "sessionId":"...", "lat":42.69, "lng":23.32,
  "accuracy":8.0, "speed":1.2, "heading":270.0, "timestamp":1750000000123 }
```
Response `202`. Pushes an SSE `location` event to dashboards.

### `POST /api/v1/audio`
Body: raw audio bytes (a complete, self-contained `.m4a`/AAC segment — NOT a raw
PCM fragment, so the dashboard can play each segment standalone).
Headers:
- `Content-Type: audio/mp4`
- `X-Device-Id`, `X-Session-Id`
- `X-Seq` — monotonically increasing segment index
- `X-Started-At` — epoch ms when the segment began
- `X-Duration-Ms` — segment length
Response `201 {"url":"/media/<deviceId>/<sessionId>/seg_<seq>.m4a"}`.
Pushes an SSE `audio` event with that metadata + url.

### `GET /api/v1/events`  (Server-Sent Events)
The dashboard subscribes here. Event types: `hello`, `session`, `location`,
`audio`, `stopped`. Each `data:` line is JSON.

### `POST /api/v1/session/stop`
`{ "deviceId":"...", "sessionId":"..." }` → `200`. Marks the session stopped and
emits `stopped`.

### `DELETE /api/v1/device/:deviceId`
Purges all stored audio + state for that device. `200 {"deleted":true}`.
This is the "delete everything" control the transparency model promises.

### `GET /media/...`
Static serving of stored audio segments.

### `GET /`
The live dashboard (map + status + segment playback).
