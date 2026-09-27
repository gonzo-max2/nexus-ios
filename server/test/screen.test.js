'use strict';
process.env.LOG_LEVEL = 'error';
const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { createServer } = require('../server');
const { ScreenStream } = require('../src/screen');

const jpeg = Buffer.from([0xff, 0xd8, 0xff, 0xe0, 1, 2, 3, 0xff, 0xd9]);
const token = 'screen-test-token';
const auth = { Authorization: `Bearer ${token}` };

async function boot(t, overrides = {}) {
  const tmp = fs.mkdtempSync(path.join(os.tmpdir(), 'nexus-screen-test-'));
  const app = createServer({ dataDir: tmp, ingestToken: token, ...overrides });
  await new Promise((resolve, reject) => {
    app.server.once('error', reject);
    app.server.listen(0, '127.0.0.1', resolve);
  });
  const base = `http://127.0.0.1:${app.server.address().port}`;
  t.after(async () => {
    app.sse.closeAll();
    app.server.closeAllConnections();
    await new Promise((resolve) => app.server.close(resolve));
    app.store.flush();
    fs.rmSync(tmp, { recursive: true, force: true });
  });
  return { ...app, base, tmp };
}
async function register(base, id = 'xr') {
  const r = await fetch(`${base}/api/v1/session`, { method: 'POST',
    headers: { ...auth, 'Content-Type': 'application/json' },
    body: JSON.stringify({ deviceId: id, deviceName: 'Test XR', consentAcknowledged: true }) });
  assert.equal(r.status, 200);
  return (await r.json()).sessionId;
}
function upload(base, sid, { seq = 0, bytes = jpeg, id = 'xr', type = 'image/jpeg' } = {}) {
  return fetch(`${base}/api/v1/screen`, { method: 'POST', body: bytes,
    headers: { ...auth, 'Content-Type': type, 'X-Device-Id': id, 'X-Session-Id': sid, 'X-Seq': String(seq) } });
}

test('screen reads and writes require a token even on an otherwise open server', async (t) => {
  const { base } = await boot(t, { ingestToken: '' });
  assert.equal((await fetch(`${base}/api/v1/screen/xr`)).status, 503);
  assert.equal((await upload(base, 'session')).status, 503);
});

test('authenticated screen frames round-trip and unchanged polls avoid retransmitting bytes', async (t) => {
  const { base, store } = await boot(t);
  const sid = await register(base);
  assert.equal((await upload(base, sid)).status, 202);
  assert.equal((await fetch(`${base}/api/v1/screen/xr`)).status, 401);
  const frame = await fetch(`${base}/api/v1/screen/xr`, { headers: auth });
  assert.equal(frame.status, 200);
  assert.equal(frame.headers.get('cache-control'), 'no-store');
  assert.equal(frame.headers.get('content-type'), 'image/jpeg');
  assert.deepEqual(Buffer.from(await frame.arrayBuffer()), jpeg);
  const unchanged = await fetch(`${base}/api/v1/screen/xr`, {
    headers: { ...auth, 'If-None-Match': frame.headers.get('etag') } });
  assert.equal(unchanged.status, 304);
  assert.equal((await unchanged.arrayBuffer()).byteLength, 0);
  assert.equal(store.devices.get('xr').segments.length, 0, 'Screen frames must not enter archived media');
});

test('unregistered and stopped sessions cannot upload and stop clears the live frame', async (t) => {
  const { base } = await boot(t);
  assert.equal((await upload(base, 'unknown')).status, 409);
  const sid = await register(base);
  assert.equal((await upload(base, sid)).status, 202);
  const stop = await fetch(`${base}/api/v1/screen/stop`, { method: 'POST',
    headers: { ...auth, 'Content-Type': 'application/json' },
    body: JSON.stringify({ deviceId: 'xr', sessionId: sid }) });
  assert.equal(stop.status, 200);
  assert.equal((await fetch(`${base}/api/v1/screen/xr`, { headers: auth })).status, 404);
  assert.equal((await upload(base, sid, { seq: 1 })).status, 409);
});

test('frame validation rejects wrong content, malformed sequence, and oversized requests', async (t) => {
  const { base } = await boot(t);
  const sid = await register(base);
  assert.equal((await upload(base, sid, { type: 'text/html' })).status, 415);
  assert.equal((await upload(base, sid, { bytes: Buffer.from('not a jpeg') })).status, 400);
  assert.equal((await upload(base, sid, { seq: -1 })).status, 400);
  assert.equal((await upload(base, sid, { bytes: Buffer.alloc(1024 * 1024 + 1) })).status, 413);
});

test('older frames cannot replace newer ones and deleting a device clears its screen', async (t) => {
  const { base } = await boot(t);
  const sid = await register(base);
  assert.equal((await upload(base, sid, { seq: 2 })).status, 202);
  assert.equal((await upload(base, sid, { seq: 1 })).status, 409);
  assert.equal((await upload(base, sid, { seq: 2 })).status, 409);
  assert.equal((await fetch(`${base}/api/v1/device/xr`, { method: 'DELETE', headers: auth })).status, 200);
  assert.equal((await fetch(`${base}/api/v1/screen/xr`, { headers: auth })).status, 404);
});

test('screen memory is bounded and stale frames expire without a stop notification', () => {
  let now = 0;
  const store = { devices: new Map() };
  for (const id of ['a', 'b', 'c']) store.devices.set(id, { sessions: new Map([['s', { stopped: false }]]) });
  const stream = new ScreenStream(store, { now: () => now, ttlMs: 100, maxDevices: 2 });
  assert.equal(stream.put('a', 's', 0, jpeg).status, 202);
  assert.equal(stream.put('b', 's', 0, jpeg).status, 202);
  assert.equal(stream.put('c', 's', 0, jpeg).status, 202);
  assert.equal(stream.frames.size, 2);
  assert.equal(stream.get('a'), null);
  now = 100;
  assert.equal(stream.get('b'), null);
  assert.equal(stream.get('c'), null);
  assert.equal(stream.frames.size, 0);
});

test('an in-flight frame cannot resurrect a stopped session', () => {
  const session = { stopped: false };
  const store = { devices: new Map([['xr', { sessions: new Map([['s', session]]) }]]) };
  const stream = new ScreenStream(store);
  assert.equal(stream.activeSession('xr', 's'), true);
  session.stopped = true; // Session stops while HTTP request body is still arriving.
  assert.equal(stream.put('xr', 's', 0, jpeg).status, 409);
  assert.equal(stream.get('xr'), null);
});
