'use strict';
(() => {
  const el = (id) => document.getElementById(id);
  const image = el('screenImage');
  const status = el('screenStatus');
  const placeholder = el('screenPlaceholder');
  const devices = el('screenDevice');
  let token = '', connected = false, busy = false, request = null, generation = 0;
  let objectURL = null, etag = '', lastFrameAt = 0;

  function showStatus(message, live = false) {
    status.textContent = message;
    status.dataset.live = String(live);
  }
  function clearFrame(message) {
    image.hidden = true;
    image.removeAttribute('src');
    if (objectURL) URL.revokeObjectURL(objectURL);
    objectURL = null;
    etag = '';
    lastFrameAt = 0;
    placeholder.hidden = false;
    placeholder.textContent = message;
  }
  function reset(message) {
    generation += 1;
    request?.abort();
    clearFrame(message);
    showStatus(message);
  }
  async function poll() {
    if (!connected || !token || !devices.value || document.hidden || busy) return;
    busy = true;
    const current = generation;
    const controller = new AbortController();
    request = controller;
    const timeout = setTimeout(() => controller.abort(), 4000);
    try {
      const headers = { Authorization: `Bearer ${token}` };
      if (etag) headers['If-None-Match'] = etag;
      const response = await fetch(`/api/v1/screen/${encodeURIComponent(devices.value)}`,
        { headers, cache: 'no-store', signal: controller.signal });
      if (current !== generation) return;
      if ([401, 403, 503].includes(response.status)) {
        connected = false;
        const message = response.status === 503 ? 'Set INGEST_TOKEN on the server first.' : 'Access denied. Check the screen token.';
        clearFrame(message);
        showStatus(message);
        return;
      }
      if (response.status === 404) {
        clearFrame('No live screen. Start or resume the screen broadcast on the iPhone.');
        showStatus('Screen offline');
        return;
      }
      if (response.status !== 200 && response.status !== 304) throw new Error(`HTTP ${response.status}`);
      const age = Number(response.headers.get('X-Frame-Age-Ms'));
      if (!Number.isFinite(age) || age < 0) throw new Error('Invalid frame age');
      if (response.status === 200) {
        const blob = await response.blob();
        if (current !== generation) return;
        if (blob.type !== 'image/jpeg') throw new Error('Invalid screen frame');
        const nextURL = URL.createObjectURL(blob);
        image.src = nextURL;
        if (objectURL) URL.revokeObjectURL(objectURL);
        objectURL = nextURL;
        image.hidden = false;
        placeholder.hidden = true;
        etag = response.headers.get('ETag') || '';
      }
      lastFrameAt = Date.now() - age;
      showStatus(age < 3000 ? 'Live screen' : `Waiting · frame ${Math.floor(age / 1000)}s old`, age < 3000);
    } catch (error) {
      if (current === generation) showStatus('Connection interrupted — reconnecting');
    } finally {
      clearTimeout(timeout);
      busy = false;
      if (request === controller) request = null;
    }
  }
  el('screenConnect').addEventListener('submit', (event) => {
    event.preventDefault();
    token = el('screenToken').value.trim();
    connected = Boolean(token && devices.value);
    reset(connected ? 'Connecting…' : 'Choose a device and enter its server token.');
    poll();
  });
  el('screenDisconnect').addEventListener('click', () => {
    connected = false;
    token = '';
    el('screenToken').value = '';
    reset('Viewer disconnected. Stop broadcasting on the iPhone to end sharing.');
  });
  devices.addEventListener('change', () => { reset('Connecting…'); poll(); });
  window.addEventListener('nexus:devices', (event) => {
    const previous = devices.value;
    const entries = event.detail || [];
    devices.replaceChildren(...entries.map((device) => {
      const option = document.createElement('option');
      option.value = device.deviceId;
      option.textContent = device.deviceName || device.deviceId;
      return option;
    }));
    if (entries.some((device) => device.deviceId === previous)) devices.value = previous;
    if (devices.value !== previous) reset('Select this iPhone and view its screen.');
  });
  document.addEventListener('visibilitychange', () => {
    reset(document.hidden ? 'Viewer paused while this tab is hidden.' : 'Connecting…');
    if (!document.hidden) poll();
  });
  setInterval(() => {
    if (lastFrameAt && Date.now() - lastFrameAt >= 10000) {
      clearFrame('Screen feed expired. Start or resume the broadcast on the iPhone.');
      showStatus('Screen offline');
    } else if (lastFrameAt && Date.now() - lastFrameAt >= 3000) {
      showStatus(`Waiting · frame ${Math.floor((Date.now() - lastFrameAt) / 1000)}s old`);
    }
    poll();
  }, 500);
})();
