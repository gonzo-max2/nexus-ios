'use strict';
const fs = require('fs');
const path = require('path');
const crypto = require('crypto');
const { URL } = require('url');
const { safeSegment, validLat, validLng, isFiniteNum } = require('./util');
const { ScreenStream } = require('./screen');

const PUBLIC_DIR = path.join(__dirname, '..', 'public');
const STATIC_TYPES = {
  '.html': 'text/html; charset=utf-8', '.js': 'text/javascript', '.css': 'text/css',
  '.m4a': 'audio/mp4', '.json': 'application/json', '.svg': 'image/svg+xml',
};

function readBody(req, limit) {
  return new Promise((resolve, reject) => {
    const chunks = []; let size = 0; let tooLarge = false;
    req.on('data', (c) => {
      if (tooLarge) return;
      size += c.length;
      if (size > limit) {
        tooLarge = true;
        chunks.length = 0;
        reject(Object.assign(new Error('payload too large'), { statusCode: 413 }));
        return;
      }
      chunks.push(c);
    });
    req.on('end', () => resolve(Buffer.concat(chunks)));
    req.on('error', reject);
    req.on('aborted', () => reject(Object.assign(new Error('request aborted'), { statusCode: 400 })));
  });
}
async function readJson(req, limit) {
  const buf = await readBody(req, limit);
  if (buf.length === 0) return {};
  try { return JSON.parse(buf.toString('utf8')); }
  catch (_) { throw Object.assign(new Error('invalid json'), { statusCode: 400 }); }
}

function createHandler({ config, store, sse, rateLimit, logger }) {
  const screen = new ScreenStream(store);
  function cors(res) {
    res.setHeader('Access-Control-Allow-Origin', config.corsOrigin);
    res.setHeader('Vary', 'Origin');
  }
  function json(res, code, obj) {
    const body = JSON.stringify(obj);
    cors(res);
    res.writeHead(code, { 'Content-Type': 'application/json', 'Content-Length': Buffer.byteLength(body) });
    res.end(body);
  }
  function authOk(req) {
    if (!config.ingestToken) return true;
    return req.headers['authorization'] === `Bearer ${config.ingestToken}`;
  }
  function clientKey(req, deviceId) {
    return deviceId ? `d:${deviceId}` : `ip:${req.socket.remoteAddress || 'unknown'}`;
  }
  function serveStatic(res, baseDir, relPath) {
    const full = path.normalize(path.join(baseDir, decodeURIComponent(relPath)));
    if (full !== baseDir && !full.startsWith(baseDir + path.sep)) return json(res, 403, { error: 'forbidden' });
    fs.readFile(full, (err, data) => {
      if (err) return json(res, 404, { error: 'not_found' });
      cors(res);
      res.writeHead(200, { 'Content-Type': STATIC_TYPES[path.extname(full).toLowerCase()] || 'application/octet-stream' });
      res.end(data);
    });
  }

  async function handleSession(req, res) {
    const body = await readJson(req, config.maxJsonBytes);
    if (body.consentAcknowledged !== true) {
      return json(res, 403, { error: 'consent_required',
        message: 'Server refuses data without explicit consentAcknowledged:true.' });
    }
    const deviceId = safeSegment(body.deviceId);
    if (!deviceId) return json(res, 400, { error: 'deviceId_required' });
    const sessionId = crypto.randomUUID();
    const d = store.addSession(deviceId, body.deviceName, sessionId, body.startedAt);
    sse.broadcast('session', { deviceId, deviceName: d.deviceName, sessionId });
    logger.info('session.started', { deviceId, sessionId });
    return json(res, 200, { sessionId });
  }

  async function handleLocation(req, res) {
    const body = await readJson(req, config.maxJsonBytes);
    const deviceId = safeSegment(body.deviceId);
    if (!deviceId) return json(res, 400, { error: 'deviceId_required' });
    if (!validLat(body.lat) || !validLng(body.lng)) return json(res, 400, { error: 'invalid_coordinates' });
    const loc = {
      lat: body.lat, lng: body.lng,
      accuracy: isFiniteNum(body.accuracy) ? body.accuracy : null,
      speed: isFiniteNum(body.speed) ? body.speed : null,
      heading: isFiniteNum(body.heading) ? body.heading : null,
      timestamp: isFiniteNum(body.timestamp) ? body.timestamp : Date.now(),
      sessionId: safeSegment(body.sessionId) || null,
    };
    const d = store.setLocation(deviceId, loc);
    sse.broadcast('location', { deviceId, deviceName: d.deviceName, ...loc });
    return json(res, 202, { ok: true });
  }

  const KIND_EXT = { audio: 'm4a', video: 'mp4', photo: 'jpg' };
  const KIND_TYPE = { audio: 'audio/mp4', video: 'video/mp4', photo: 'image/jpeg' };

  async function handleMedia(req, res, kindOverride) {
    const deviceId = safeSegment(req.headers['x-device-id']);
    const sessionId = safeSegment(req.headers['x-session-id']);
    const seq = safeSegment(req.headers['x-seq'] || '0');
    if (!deviceId || !sessionId) return json(res, 400, { error: 'device_session_headers_required' });
    const kind = ['audio', 'video', 'photo'].includes(kindOverride)
      ? kindOverride
      : (['audio', 'video', 'photo'].includes(req.headers['x-media-kind']) ? req.headers['x-media-kind'] : 'audio');
    const bytes = await readBody(req, config.maxAudioBytes);
    if (bytes.length === 0) return json(res, 400, { error: 'empty_body' });
    const rec = store.addMedia(deviceId, sessionId, seq, bytes, {
      kind,
      ext: safeSegment(req.headers['x-file-ext'] || KIND_EXT[kind] || 'bin'),
      contentType: req.headers['content-type'] || KIND_TYPE[kind],
      startedAt: parseInt(req.headers['x-started-at'] || '0', 10) || null,
      durationMs: parseInt(req.headers['x-duration-ms'] || '0', 10) || null,
    });
    const d = store.device(deviceId);
    sse.broadcast('media', { deviceId, deviceName: d.deviceName, ...rec });
    return json(res, 201, { url: rec.url });
  }

  async function handleStop(req, res) {
    const body = await readJson(req, config.maxJsonBytes);
    const deviceId = safeSegment(body.deviceId);
    const sessionId = safeSegment(body.sessionId);
    store.stopSession(deviceId, sessionId);
    sse.broadcast('stopped', { deviceId, sessionId });
    logger.info('session.stopped', { deviceId, sessionId });
    return json(res, 200, { ok: true });
  }

  async function handleTelemetry(req, res) {
    const body = await readJson(req, config.maxJsonBytes);
    const deviceId = safeSegment(body.deviceId);
    if (!deviceId) return json(res, 400, { error: 'deviceId_required' });
    const d = store.device(deviceId);
    const telemetry = {
      deviceId,
      deviceName: d.deviceName,
      sessionId: safeSegment(body.sessionId) || null,
      timestamp: isFiniteNum(body.timestamp) ? body.timestamp : Date.now(),
      battery: body.battery || null,
      sensors: body.sensors || null,
      motion: body.motion || null,
      steps: isFiniteNum(body.steps) ? body.steps : null,
      pressure: isFiniteNum(body.pressure) ? body.pressure : null,
    };
    d.lastTelemetry = telemetry;
    sse.broadcast('telemetry', telemetry);
    return json(res, 202, { ok: true });
  }

  function handleDelete(res, deviceId) {
    const id = safeSegment(deviceId);
    store.deleteDevice(id);
    screen.deleteDevice(id);
    sse.broadcast('deleted', { deviceId: id });
    logger.info('device.deleted', { deviceId: id });
    return json(res, 200, { deleted: true });
  }

  return async function handler(req, res) {
    const started = process.hrtime.bigint();
    try {
      const u = new URL(req.url, `http://${req.headers.host || 'localhost'}`);
      const p = u.pathname;

      if (req.method === 'OPTIONS') {
        cors(res);
        res.writeHead(204, {
          'Access-Control-Allow-Methods': 'GET,POST,DELETE,OPTIONS',
          'Access-Control-Allow-Headers': 'Content-Type,Authorization,X-Device-Id,X-Session-Id,X-Seq,X-Started-At,X-Duration-Ms,X-Media-Kind,X-File-Ext,Last-Event-ID',
        });
        return res.end();
      }

      if (p === '/api/v1/health') {
        return json(res, 200, { ok: true, uptimeSec: Math.round(process.uptime()), devices: store.devices.size });
      }
      if (p === '/api/v1/devices' && req.method === 'GET') return json(res, 200, { devices: store.publicDevices() });
      if (p === '/api/v1/events' && req.method === 'GET') return sse.addClient(req, res, { devices: store.publicDevices() });

      const isIngest = p.startsWith('/api/v1/') && !['/api/v1/health', '/api/v1/devices', '/api/v1/events'].includes(p);
      if (isIngest) {
        if (!authOk(req)) return json(res, 401, { error: 'unauthorized' });
        const key = clientKey(req, safeSegment(req.headers['x-device-id']));
        if (!rateLimit(key)) return json(res, 429, { error: 'rate_limited' });
      }

      // Screen content always requires a configured token, including reads.
      if (p === '/api/v1/screen' || p.startsWith('/api/v1/screen/')) {
        res.setHeader('Cache-Control', 'no-store');
        if (!config.ingestToken) return json(res, 503, { error: 'screen_requires_ingest_token' });
        const validId = (value) => typeof value === 'string' && /^[A-Za-z0-9_-]{1,128}$/.test(value);
        if (p === '/api/v1/screen' && req.method === 'POST') {
          const deviceId = req.headers['x-device-id'];
          const sessionId = req.headers['x-session-id'];
          const sequence = req.headers['x-seq'];
          if (!validId(deviceId) || !validId(sessionId) || !/^\d+$/.test(sequence || '')) {
            return json(res, 400, { error: 'invalid_screen_headers' });
          }
          if (req.headers['content-type'] !== 'image/jpeg') return json(res, 415, { error: 'jpeg_required' });
          if (!screen.activeSession(deviceId, sessionId)) return json(res, 409, { error: 'screen_session_inactive' });
          const bytes = await readBody(req, screen.maxBytes);
          const result = screen.put(deviceId, sessionId, Number(sequence), bytes);
          return json(res, result.status, result.error ? { error: result.error } : { ok: true });
        }
        if (p === '/api/v1/screen/stop' && req.method === 'POST') {
          const body = await readJson(req, config.maxJsonBytes);
          if (!validId(body?.deviceId) || !validId(body?.sessionId)) return json(res, 400, { error: 'invalid_screen_session' });
          screen.stop(body.deviceId, body.sessionId);
          sse.broadcast('stopped', { deviceId: body.deviceId, sessionId: body.sessionId });
          return json(res, 200, { ok: true });
        }
        const match = p.match(/^\/api\/v1\/screen\/([A-Za-z0-9_-]{1,128})$/);
        if (match && req.method === 'GET') {
          const frame = screen.get(match[1]);
          if (!frame) return json(res, 404, { error: 'screen_offline' });
          cors(res);
          const etag = `"${frame.sessionId}:${frame.seq}"`;
          res.setHeader('ETag', etag);
          res.setHeader('X-Frame-Age-Ms', String(Math.max(0, Date.now() - frame.receivedAt)));
          if (req.headers['if-none-match'] === etag) {
            res.writeHead(304);
            return res.end();
          }
          res.writeHead(200, { 'Content-Type': 'image/jpeg', 'Content-Length': frame.bytes.length,
            'X-Frame-Seq': String(frame.seq), 'X-Received-At': String(frame.receivedAt) });
          return res.end(frame.bytes);
        }
        return json(res, 404, { error: 'not_found' });
      }

      if (p === '/api/v1/session' && req.method === 'POST') return await handleSession(req, res);
      if (p === '/api/v1/location' && req.method === 'POST') return await handleLocation(req, res);
      if (p === '/api/v1/media' && req.method === 'POST') return await handleMedia(req, res);
      if (p === '/api/v1/audio' && req.method === 'POST') return await handleMedia(req, res, 'audio');
      if (p === '/api/v1/session/stop' && req.method === 'POST') return await handleStop(req, res);
      if (p === '/api/v1/telemetry' && req.method === 'POST') return await handleTelemetry(req, res);

      const del = p.match(/^\/api\/v1\/device\/([^/]+)$/);
      if (del && req.method === 'DELETE') return handleDelete(res, del[1]);

      if (p.startsWith('/media/')) return serveStatic(res, config.dataDir, p.slice('/media/'.length));
      if (p === '/' || p === '/index.html') return serveStatic(res, PUBLIC_DIR, 'index.html');
      if (p.startsWith('/') && !p.includes('..')) return serveStatic(res, PUBLIC_DIR, p.slice(1));

      return json(res, 404, { error: 'not_found' });
    } catch (err) {
      const code = err.statusCode || 500;
      if (code >= 500) logger.error('request.error', { err: String(err.message || err) });
      return json(res, code, { error: code === 413 ? 'payload_too_large' : (err.message || 'server_error') });
    } finally {
      const ms = Number(process.hrtime.bigint() - started) / 1e6;
      if (ms > 500) logger.warn('request.slow', { path: req.url, ms: Math.round(ms) });
    }
  };
}
module.exports = { createHandler, readBody, readJson };
