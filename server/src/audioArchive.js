'use strict';
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const crypto = require('node:crypto');
const { spawn } = require('node:child_process');

class AudioArchive {
  constructor(store, config) {
    this.store = store;
    this.config = config;
    this.windowMs = config.audioBatchMinutes * 60000;
    this.exporting = false;
  }

  batches(deviceId) {
    const device = this.store.devices.get(deviceId);
    if (!device) return [];
    const batches = new Map();
    for (const segment of device.segments) {
      if (segment.kind !== 'audio') continue;
      const timestamp = segment.startedAt || segment.receivedAt;
      const start = Math.floor(timestamp / this.windowMs) * this.windowMs;
      const id = `${segment.sessionId}:${start}`;
      if (!batches.has(id)) batches.set(id, {
        deviceId, sessionId: segment.sessionId, start, end: start + this.windowMs,
        bytes: 0, durationMs: 0, segments: [],
        collecting: device.sessions.get(segment.sessionId)?.stopped === false && Date.now() < start + this.windowMs,
      });
      const batch = batches.get(id);
      batch.bytes += segment.bytes || 0;
      batch.durationMs += segment.durationMs || 0;
      batch.segments.push(segment);
    }
    for (const batch of batches.values()) {
      batch.segments.sort((a, b) => (a.startedAt || a.receivedAt) - (b.startedAt || b.receivedAt) || Number(a.seq) - Number(b.seq));
    }
    return [...batches.values()].sort((a, b) => b.start - a.start);
  }

  summaries(deviceId) {
    return this.batches(deviceId).map(({ segments, ...batch }) => ({ ...batch, segmentCount: segments.length }));
  }

  find(deviceId, sessionId, start) {
    return this.batches(deviceId).find((batch) => batch.sessionId === sessionId && batch.start === start);
  }

  async exportBatch(batch) {
    if (this.exporting) throw Object.assign(new Error('Another audio export is running. Try again shortly.'), { statusCode: 429 });
    if (batch.bytes > 128 * 1024 * 1024) throw Object.assign(new Error('Batch exceeds the 128 MiB export limit.'), { statusCode: 413 });
    this.exporting = true;
    let directory;
    try {
      directory = await fs.promises.mkdtemp(path.join(os.tmpdir(), 'nexus-audio-export-'));
      const root = await fs.promises.realpath(this.config.dataDir);
      const files = [];
      const manifest = { format: 'nexus-audio-batch-v1', deviceId: batch.deviceId, sessionId: batch.sessionId,
        windowStartedAt: batch.start, windowEndedAt: batch.end, exportedAt: Date.now(),
        note: 'Original AAC segments in capture order. Gaps remain gaps; this is not a continuous recording.', files: [] };
      for (const segment of batch.segments) {
        const file = await fs.promises.realpath(path.resolve(root, segment.url.replace(/^\/media\//, '')));
        if (!file.startsWith(root + path.sep)) throw Object.assign(new Error('Invalid archive path'), { statusCode: 400 });
        const hash = crypto.createHash('sha256');
        for await (const chunk of fs.createReadStream(file)) hash.update(chunk);
        files.push(file);
        manifest.files.push({ name: path.basename(file), seq: segment.seq,
          startedAt: segment.startedAt, durationMs: segment.durationMs, bytes: segment.bytes, sha256: hash.digest('hex') });
      }
      const manifestPath = path.join(directory, 'manifest.json');
      await fs.promises.writeFile(manifestPath, JSON.stringify(manifest, null, 2), { mode: 0o600 });
      const archivePath = path.join(directory, 'batch.zip');
      await new Promise((resolve, reject) => {
        const child = spawn('zip', ['-q', '-0', '-j', archivePath, '--', manifestPath, ...files], { stdio: ['ignore', 'ignore', 'pipe'] });
        let detail = '';
        child.stderr.on('data', (chunk) => { if (detail.length < 2000) detail += chunk.toString(); });
        child.on('error', (error) => reject(new Error(`Audio export requires the zip command: ${error.message}`)));
        child.on('close', (code) => code === 0 ? resolve() : reject(new Error(`Audio export failed (${code}): ${detail}`)));
      });
      return { path: archivePath,
        filename: `nexus-audio-${batch.deviceId.replace(/[^A-Za-z0-9_-]/g, '_')}-${batch.start}.zip`,
        cleanup: () => fs.promises.rm(directory, { recursive: true, force: true }) };
    } catch (error) {
      if (directory) await fs.promises.rm(directory, { recursive: true, force: true });
      throw error;
    } finally {
      this.exporting = false;
    }
  }
}
module.exports = { AudioArchive };
