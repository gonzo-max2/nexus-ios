'use strict';
// Optional browser integration test. Requires Playwright in NODE_PATH and Chrome.
// Uses a visibly labeled synthetic frame; it does not simulate proof of an iPhone capture.
process.env.LOG_LEVEL = 'error';
const { chromium } = require('playwright');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const assert = require('node:assert/strict');
const { createServer } = require('../server');

(async () => {
  const tmp = fs.mkdtempSync(path.join(os.tmpdir(), 'nexus-screen-ui-'));
  const output = path.resolve(__dirname, '../../build-output/ui-qa');
  fs.mkdirSync(output, { recursive: true });
  const token = 'local-ui-test-only';
  const app = createServer({ dataDir: tmp, ingestToken: token });
  const browser = await chromium.launch({ executablePath: process.env.CHROME_PATH || '/usr/bin/google-chrome',
    headless: true, args: ['--no-sandbox'] });
  let feed;
  try {
    await new Promise((resolve) => app.server.listen(0, '127.0.0.1', resolve));
    const base = `http://127.0.0.1:${app.server.address().port}`;
    const auth = { Authorization: `Bearer ${token}`, 'Content-Type': 'application/json' };
    const registration = await fetch(`${base}/api/v1/session`, { method: 'POST', headers: auth,
      body: JSON.stringify({ deviceId: 'xr-test', deviceName: 'iPhone XR — test fixture', consentAcknowledged: true }) });
    const { sessionId } = await registration.json();
    const page = await browser.newPage({ viewport: { width: 1440, height: 1000 } });
    const errors = [];
    page.on('pageerror', (error) => errors.push(error.message));
    // Screen viewing must not depend on availability of map CDN scripts.
    await page.route('https://**/*', (route) => route.abort());
    await page.goto(base);
    await page.locator('#screenDevice option[value="xr-test"]').waitFor({ state: 'attached' });
    await page.locator('#screenToken').fill('wrong-token');
    await page.getByRole('button', { name: 'View screen', exact: true }).click();
    await page.getByRole('status').filter({ hasText: 'Access denied' }).waitFor();

    const encoded = await page.evaluate(() => {
      const canvas = document.createElement('canvas'); canvas.width = 414; canvas.height = 896;
      const ctx = canvas.getContext('2d');
      ctx.fillStyle = '#10233c'; ctx.fillRect(0, 0, canvas.width, canvas.height);
      ctx.fillStyle = '#fff'; ctx.font = 'bold 22px sans-serif';
      ctx.fillText('SYNTHETIC TEST FRAME', 45, 110);
      ctx.font = '16px sans-serif'; ctx.fillText('Dashboard transport / layout check', 50, 150);
      ctx.fillStyle = '#44bd95'; ctx.fillRect(70, 230, 274, 300);
      ctx.fillStyle = '#fff'; ctx.fillText('Not a physical iPhone broadcast', 55, 650);
      return canvas.toDataURL('image/jpeg').split(',')[1];
    });
    const bytes = Buffer.from(encoded, 'base64');
    let seq = 0;
    const upload = () => fetch(`${base}/api/v1/screen`, { method: 'POST', body: bytes,
      headers: { ...auth, 'Content-Type': 'image/jpeg', 'X-Device-Id': 'xr-test',
        'X-Session-Id': sessionId, 'X-Seq': String(seq++) } });
    assert.equal((await upload()).status, 202);
    feed = setInterval(() => { upload().catch(() => {}); }, 700);
    await page.locator('#screenToken').fill(token);
    await page.getByRole('button', { name: 'View screen', exact: true }).click();
    await page.waitForFunction(() => document.getElementById('screenImage').naturalWidth === 414);
    await page.getByRole('status').filter({ hasText: 'Live screen' }).waitFor();
    await page.screenshot({ path: path.join(output, 'screen-live-desktop.png'), fullPage: true });
    assert.equal(await page.evaluate(() => localStorage.length + sessionStorage.length), 0);
    await page.setViewportSize({ width: 390, height: 844 });
    await page.screenshot({ path: path.join(output, 'screen-live-mobile.png'), fullPage: true });
    assert.equal(await page.evaluate(() => document.documentElement.scrollWidth <= innerWidth), true);

    clearInterval(feed); feed = null;
    await page.waitForFunction(() => document.getElementById('screenStatus').textContent.startsWith('Waiting'), { timeout: 5000 });
    await page.waitForFunction(() => document.getElementById('screenImage').hidden, null, { timeout: 12000 });
    assert.equal(await page.locator('#screenStatus').getAttribute('data-live'), 'false');
    await upload();
    await page.waitForFunction(() => !document.getElementById('screenImage').hidden);
    await fetch(`${base}/api/v1/screen/stop`, { method: 'POST', headers: auth,
      body: JSON.stringify({ deviceId: 'xr-test', sessionId }) });
    await page.waitForFunction(() => document.getElementById('screenImage').hidden);
    await page.screenshot({ path: path.join(output, 'screen-offline-mobile.png'), fullPage: true });
    await page.getByRole('button', { name: 'Disconnect', exact: true }).click();
    assert.equal(await page.locator('#screenToken').inputValue(), '');
    assert.deepEqual(errors, []);
    console.log('PASS browser: auth, decoded live frame, desktop/mobile layout, stale expiry, restart, stop, token cleanup, no page errors');
    console.log(`Screenshots: ${output}`);
  } finally {
    clearInterval(feed);
    await browser.close();
    app.sse.closeAll();
    app.server.closeAllConnections();
    await new Promise((resolve) => app.server.close(resolve));
    app.store.flush();
    fs.rmSync(tmp, { recursive: true, force: true });
  }
})().catch((error) => { console.error(error); process.exitCode = 1; });
