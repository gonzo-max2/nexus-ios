'use strict';
const fs = require('fs');
const path = require('path');
const { safeSegment } = require('./util');

/**
 * Device/session/segment index with disk persistence + retention.
 * Audio bytes live as files on disk; only lightweight metadata is indexed and
 * persisted to index.json so the dashboard survives a server restart.
 */
class Store {
  constructor(config, logger) {
    this.cfg = config;
    this.log = logger;
    this.devices = new Map();
    this._saveTimer = null;
    this._indexPath = path.join(config.dataDir, 'index.json');
    fs.mkdirSync(config.dataDir, { recursive: true });
    this.load();
  }

  load() {
    try {
      const raw = JSON.parse(fs.readFileSync(this._indexPath, 'utf8'));
      for (const d of raw.devices || []) {
        this.devices.set(d.deviceId, {
          deviceId: d.deviceId,
          deviceName: d.deviceName || d.deviceId,
          sessions: new Map((d.sessions || []).map((s) => [s.sessionId, s])),
          lastLocation: d.lastLocation || null,
          lastSeenAt: d.lastSeenAt || Date.now(),
          segments: d.segments || [],
        });
      }
      this.log.info('store.loaded', { devices: this.devices.size });
    } catch (_) { /* first boot: no index yet */ }
  }

  _snapshot() {
    return {
      savedAt: Date.now(),
      devices: [...this.devices.values()].map((d) => ({
        deviceId: d.deviceId, deviceName: d.deviceName,
        sessions: [...d.sessions.values()],
        lastLocation: d.lastLocation, lastSeenAt: d.lastSeenAt, segments: d.segments,
      })),
    };
  }

  _writeSync() {
    const tmp = this._indexPath + '.tmp';
    try {
      fs.writeFileSync(tmp, JSON.stringify(this._snapshot()));
      fs.renameSync(tmp, this._indexPath); // atomic replace
    } catch (e) { this.log.error('store.persist_failed', { err: String(e.message || e) }); }
  }

  /** Debounced async save; coalesces bursts of mutations into one write. */
  persist() {
    if (this._saveTimer) return;
    this._saveTimer = setTimeout(() => { this._saveTimer = null; this._writeSync(); }, 250);
    this._saveTimer.unref?.();
  }

  /** Immediate synchronous save (used on graceful shutdown). */
  flush() {
    if (this._saveTimer) { clearTimeout(this._saveTimer); this._saveTimer = null; }
    this._writeSync();
  }

  device(deviceId, deviceName) {
    const id = safeSegment(deviceId);
    let d = this.devices.get(id);
    if (!d) {
      d = { deviceId: id, deviceName: deviceName || id, sessions: new Map(),
            lastLocation: null, lastSeenAt: Date.now(), segments: [] };
      this.devices.set(id, d);
    }
    if (deviceName) d.deviceName = deviceName;
    d.lastSeenAt = Date.now();
    return d;
  }

  addSession(deviceId, deviceName, sessionId, startedAt) {
    const d = this.device(deviceId, deviceName);
    d.sessions.set(sessionId, { sessionId, startedAt: startedAt || Date.now(), stopped: false });
    this.persist();
    return d;
  }

  stopSession(deviceId, sessionId) {
    const d = this.devices.get(safeSegment(deviceId));
    if (!d) return;
    const s = d.sessions.get(safeSegment(sessionId));
    if (s) s.stopped = true;
    this.persist();
  }

  setLocation(deviceId, loc) {
    const d = this.device(deviceId);
    d.lastLocation = loc;
    this.persist();
    return d;
  }

  /**
   * Store one media segment (audio | video | photo). Bytes are written to disk;
   * lightweight metadata is indexed. Returns the metadata record.
   */
  addMedia(deviceId, sessionId, seq, bytes, meta) {
    const id = safeSegment(deviceId);
    const sid = safeSegment(sessionId);
    const kind = ['audio', 'video', 'photo'].includes(meta.kind) ? meta.kind : 'audio';
    const ext = safeSegment(meta.ext || 'bin');
    const dir = path.join(this.cfg.dataDir, id, sid);
    fs.mkdirSync(dir, { recursive: true });
    const filename = `${kind}_${safeSegment(seq)}.${ext}`;
    const d = this.device(id);
    const url = `/media/${id}/${sid}/${filename}`;
    const existing = d.segments.find((segment) => segment.url === url);
    if (existing) {
      if (fs.readFileSync(path.join(dir, filename)).equals(bytes)) return { ...existing, duplicate: true };
      throw Object.assign(new Error('media_sequence_conflict'), { statusCode: 409 });
    }
    const filePath = path.join(dir, filename);
    fs.writeFileSync(filePath + '.tmp', bytes);
    fs.renameSync(filePath + '.tmp', filePath);
    const rec = {
      kind, seq: safeSegment(seq), sessionId: sid,
      url,
      contentType: meta.contentType || 'application/octet-stream',
      bytes: bytes.length,
      startedAt: meta.startedAt || null,
      durationMs: meta.durationMs || null,
      receivedAt: Date.now(),
    };
    d.segments.push(rec);
    this._enforceRetention(d);
    this.persist();
    return rec;
  }

  _enforceRetention(d) {
    const now = Date.now();
    const maxAge = this.cfg.retentionMaxAgeMs;
    const maxN = this.cfg.retentionMaxSegments;
    const keep = [];
    const drop = [];
    for (const s of d.segments) {
      const tooOld = maxAge > 0 && now - (s.receivedAt || now) > maxAge;
      if (tooOld) drop.push(s); else keep.push(s);
    }
    while (keep.length > maxN) drop.push(keep.shift());
    let bytes = keep.reduce((sum, segment) => sum + (segment.bytes || 0), 0);
    while (this.cfg.retentionMaxBytes > 0 && bytes > this.cfg.retentionMaxBytes && keep.length) {
      const segment = keep.shift(); bytes -= segment.bytes || 0; drop.push(segment);
    }
    for (const s of drop) {
      try { fs.rmSync(path.join(this.cfg.dataDir, s.url.replace('/media/', '')), { force: true }); }
      catch (_) { /* best effort */ }
    }
    d.segments = keep;
    if (drop.length) this.log.debug('store.retention_pruned', { deviceId: d.deviceId, pruned: drop.length });
  }

  deleteDevice(deviceId) {
    const id = safeSegment(deviceId);
    this.devices.delete(id);
    try { fs.rmSync(path.join(this.cfg.dataDir, id), { recursive: true, force: true }); }
    catch (e) { this.log.warn('store.delete_failed', { deviceId: id, err: String(e.message || e) }); }
    this.persist();
  }

  publicDevices() {
    return [...this.devices.values()].map((d) => ({
      deviceId: d.deviceId, deviceName: d.deviceName, lastSeenAt: d.lastSeenAt,
      lastLocation: d.lastLocation,
      lastTelemetry: d.lastTelemetry || null,
      activeSessions: [...d.sessions.values()].filter((s) => !s.stopped).length,
      segmentCount: d.segments.length,
      segments: d.segments.slice(-50),   // last 50 for timeline
    }));
  }
}
module.exports = { Store };
