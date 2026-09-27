'use strict';

// Live frames are transient: one bounded JPEG per device, never written to disk.
class ScreenStream {
  constructor(store, { ttlMs = 10000, maxBytes = 1024 * 1024, maxDevices = 32, now = Date.now } = {}) {
    this.store = store;
    this.frames = new Map();
    this.ttlMs = ttlMs;
    this.maxBytes = maxBytes;
    this.maxDevices = maxDevices;
    this.now = now;
  }

  activeSession(deviceId, sessionId) {
    return this.store.devices.get(deviceId)?.sessions.get(sessionId)?.stopped === false;
  }

  put(deviceId, sessionId, seq, bytes) {
    if (!this.activeSession(deviceId, sessionId)) return { status: 409, error: 'screen_session_inactive' };
    if (!Number.isSafeInteger(seq) || seq < 0) return { status: 400, error: 'invalid_sequence' };
    if (bytes.length > this.maxBytes) return { status: 413, error: 'frame_too_large' };
    if (bytes.length < 5 || bytes[0] !== 0xff || bytes[1] !== 0xd8 || bytes[2] !== 0xff ||
        bytes[bytes.length - 2] !== 0xff || bytes[bytes.length - 1] !== 0xd9) {
      return { status: 400, error: 'jpeg_required' };
    }
    const previous = this.get(deviceId);
    if (previous?.sessionId === sessionId && previous.seq >= seq) {
      return { status: 409, error: 'stale_frame' };
    }
    for (const id of this.frames.keys()) this.get(id); // Expire old frames on ingress.
    if (!this.frames.has(deviceId) && this.frames.size >= this.maxDevices) {
      this.frames.delete(this.frames.keys().next().value);
    }
    this.frames.delete(deviceId);
    this.frames.set(deviceId, { sessionId, seq, bytes, receivedAt: this.now() });
    return { status: 202 };
  }

  get(deviceId) {
    const frame = this.frames.get(deviceId);
    if (frame && (this.now() - frame.receivedAt >= this.ttlMs || !this.activeSession(deviceId, frame.sessionId))) {
      this.frames.delete(deviceId);
      return null;
    }
    return frame || null;
  }

  stop(deviceId, sessionId) {
    if (this.frames.get(deviceId)?.sessionId === sessionId) this.frames.delete(deviceId);
    this.store.stopSession(deviceId, sessionId);
  }

  deleteDevice(deviceId) { this.frames.delete(deviceId); }
}

module.exports = { ScreenStream };
