'use strict';
process.env.LOG_LEVEL = process.env.LOG_LEVEL || 'error';
/* Comprehensive zero-dep test suite for the ingest server. */
const http = require('http');
const fs = require('fs');
const os = require('os');
const path = require('path');
const assert = require('assert');
const { createServer } = require('../server.js');

let passed = 0, failed = 0;
async function test(name, fn) {
  try { await fn(); passed++; console.log('  ok   ' + name); }
  catch (e) { failed++; console.error('  FAIL ' + name + '\n       ' + (e.message || e)); }
}

function boot(overrides = {}) {
  const tmp = fs.mkdtempSync(path.join(os.tmpdir(), 'nexus-test-'));
  const { server, store } = createServer({ dataDir: tmp, ...overrides });
  return new Promise((resolve) => {
    server.listen(0, '127.0.0.1', () => {
      const port = server.address().port;
      resolve({
        base: `http://127.0.0.1:${port}`, tmp, store,
        close: () => new Promise((r) => { server.close(r); }),
      });
    });
  });
}

function req(base, method, urlPath, { headers = {}, body = null } = {}) {
  return new Promise((resolve, reject) => {
    const r = http.request(base + urlPath, { method, headers }, (res) => {
      const chunks = [];
      res.on('data', (c) => chunks.push(c));
      res.on('end', () => resolve({ status: res.statusCode, body: Buffer.concat(chunks) }));
    });
    r.on('error', reject);
    if (body) r.write(body);
    r.end();
  });
}
const jreq = (base, method, p, obj, headers = {}) =>
  req(base, method, p, { headers: { 'Content-Type': 'application/json', ...headers },
                         body: obj ? Buffer.from(JSON.stringify(obj)) : null });

function collectSSE(base, ms) {
  return new Promise((resolve) => {
    const events = [];
    const r = http.get(base + '/api/v1/events', (res) => {
      let buf = ''; res.setEncoding('utf8');
      res.on('data', (chunk) => {
        buf += chunk; let i;
        while ((i = buf.indexOf('\n\n')) >= 0) {
          const raw = buf.slice(0, i); buf = buf.slice(i + 2);
          const ev = {};
          for (const line of raw.split('\n')) {
            if (line.startsWith('event:')) ev.event = line.slice(6).trim();
            else if (line.startsWith('data:')) ev.data = line.slice(5).trim();
          }
          if (ev.event) events.push(ev);
        }
      });
    });
    setTimeout(() => { r.destroy(); resolve(events); }, ms);
  });
}
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

(async () => {
  // ---- happy path: consent, session, location, all media kinds, SSE ----
  await test('consent gate + full media pipeline', async () => {
    const s = await boot();
    const events = []; const evP = collectSSE(s.base, 900).then((e) => events.push(...e));
    await sleep(120);

    const noConsent = await jreq(s.base, 'POST', '/api/v1/session', { deviceId: 'devA', consentAcknowledged: false });
    assert.strictEqual(noConsent.status, 403, 'no-consent must 403');

    const sess = await jreq(s.base, 'POST', '/api/v1/session',
      { deviceId: 'devA', deviceName: 'Test iPhone', consentAcknowledged: true, startedAt: Date.now() });
    assert.strictEqual(sess.status, 200);
    const sessionId = JSON.parse(sess.body).sessionId;

    const loc = await jreq(s.base, 'POST', '/api/v1/location',
      { deviceId: 'devA', sessionId, lat: 42.7, lng: 23.32, accuracy: 5, timestamp: Date.now() });
    assert.strictEqual(loc.status, 202);

    for (const [kind, ext, ct] of [['audio','m4a','audio/mp4'],['video','mp4','video/mp4'],['photo','jpg','image/jpeg']]) {
      const bytes = Buffer.from(`FAKE-${kind}-BYTES`);
      const r = await req(s.base, 'POST', '/api/v1/media', {
        headers: { 'Content-Type': ct, 'X-Device-Id': 'devA', 'X-Session-Id': sessionId,
          'X-Seq': '1', 'X-Media-Kind': kind, 'X-File-Ext': ext,
          'X-Started-At': String(Date.now()), 'X-Duration-Ms': '4000' },
        body: bytes });
      assert.strictEqual(r.status, 201, kind + ' upload should 201');
      const url = JSON.parse(r.body).url;
      const served = await req(s.base, 'GET', url);
      assert.ok(served.body.equals(bytes), kind + ' served bytes must match');
      assert.ok(url.endsWith('.' + ext), kind + ' url should have ext ' + ext);
    }

    await jreq(s.base, 'POST', '/api/v1/session/stop', { deviceId: 'devA', sessionId });
    await evP;
    const kinds = events.map((e) => e.event);
    for (const k of ['hello', 'session', 'location', 'media', 'stopped'])
      assert.ok(kinds.includes(k), `SSE missing '${k}' (got ${[...new Set(kinds)].join(',')})`);
    const mediaKinds = events.filter((e) => e.event === 'media').map((e) => JSON.parse(e.data).kind);
    for (const k of ['audio','video','photo']) assert.ok(mediaKinds.includes(k), 'media event for ' + k);
    await s.close();
  });

  // ---- auth ----
  await test('bearer token enforced when configured', async () => {
    const s = await boot({ ingestToken: 'secret' });
    const noAuth = await jreq(s.base, 'POST', '/api/v1/session', { deviceId: 'd', consentAcknowledged: true });
    assert.strictEqual(noAuth.status, 401);
    const withAuth = await jreq(s.base, 'POST', '/api/v1/session',
      { deviceId: 'd', consentAcknowledged: true }, { Authorization: 'Bearer secret' });
    assert.strictEqual(withAuth.status, 200);
    // health + dashboard stay open
    assert.strictEqual((await req(s.base, 'GET', '/api/v1/health')).status, 200);
    await s.close();
  });

  // ---- rate limiting ----
  await test('rate limiter returns 429 on burst', async () => {
    const s = await boot({ rateCapacity: 3, rateRefillPerSec: 0 });
    let got429 = false;
    for (let i = 0; i < 6; i++) {
      const r = await jreq(s.base, 'POST', '/api/v1/location',
        { deviceId: 'rl', lat: 1, lng: 1 }, { 'X-Device-Id': 'rl' });
      if (r.status === 429) got429 = true;
    }
    assert.ok(got429, 'expected a 429 within burst');
    await s.close();
  });

  // ---- validation + traversal ----
  await test('invalid coordinates rejected', async () => {
    const s = await boot();
    const r = await jreq(s.base, 'POST', '/api/v1/location', { deviceId: 'd', lat: 999, lng: 0 });
    assert.strictEqual(r.status, 400);
    await s.close();
  });
  await test('path traversal on /media is blocked', async () => {
    const s = await boot();
    const r = await req(s.base, 'GET', '/media/..%2f..%2f..%2fetc%2fpasswd');
    assert.ok(r.status === 403 || r.status === 404, 'traversal must not 200 (got ' + r.status + ')');
    await s.close();
  });

  // ---- persistence across restart ----
  await test('device index survives restart', async () => {
    const tmp = fs.mkdtempSync(path.join(os.tmpdir(), 'nexus-persist-'));
    const a = createServer({ dataDir: tmp });
    await new Promise((r) => a.server.listen(0, '127.0.0.1', r));
    const base1 = `http://127.0.0.1:${a.server.address().port}`;
    await jreq(base1, 'POST', '/api/v1/session', { deviceId: 'persistDev', deviceName: 'Kept', consentAcknowledged: true });
    a.store.flush();
    await new Promise((r) => a.server.close(r));

    const b = createServer({ dataDir: tmp });
    await new Promise((r) => b.server.listen(0, '127.0.0.1', r));
    const base2 = `http://127.0.0.1:${b.server.address().port}`;
    const devs = JSON.parse((await req(base2, 'GET', '/api/v1/devices')).body).devices;
    assert.ok(devs.find((d) => d.deviceId === 'persistDev'), 'device should reload after restart');
    await new Promise((r) => b.server.close(r));
    fs.rmSync(tmp, { recursive: true, force: true });
  });

  console.log(`\n${failed === 0 ? 'PASS' : 'FAIL'}  ${passed} passed, ${failed} failed`);
  process.exit(failed ? 1 : 0);
})();
