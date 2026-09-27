'use strict';
/**
 * Server-Sent Events hub with a bounded replay buffer so a dashboard that briefly
 * disconnects can catch up via the standard Last-Event-ID header.
 */
class SSEHub {
  constructor(config, logger) {
    this.clients = new Set();
    this.buffer = [];            // { id, event, data }
    this.nextId = 1;
    this.replay = config.sseReplay;
    this.log = logger;
  }

  addClient(req, res, helloData) {
    res.writeHead(200, {
      'Content-Type': 'text/event-stream',
      'Cache-Control': 'no-cache, no-transform',
      Connection: 'keep-alive',
      'X-Accel-Buffering': 'no',
    });
    res.write('retry: 3000\n\n');
    res.write(`event: hello\ndata: ${JSON.stringify(helloData)}\n\n`);

    // Replay missed events if the client reconnected with a Last-Event-ID.
    const lastId = parseInt(req.headers['last-event-id'] || '0', 10);
    if (lastId > 0) {
      for (const e of this.buffer) {
        if (e.id > lastId) res.write(`id: ${e.id}\nevent: ${e.event}\ndata: ${e.data}\n\n`);
      }
    }

    this.clients.add(res);
    const ping = setInterval(() => { try { res.write(': ping\n\n'); } catch (_) {} }, 15000);
    ping.unref?.();
    req.on('close', () => { clearInterval(ping); this.clients.delete(res); });
    this.log.debug('sse.client_connected', { clients: this.clients.size });
  }

  broadcast(event, data) {
    const id = this.nextId++;
    const payload = JSON.stringify(data);
    this.buffer.push({ id, event, data: payload });
    if (this.buffer.length > this.replay) this.buffer.shift();
    const frame = `id: ${id}\nevent: ${event}\ndata: ${payload}\n\n`;
    for (const res of this.clients) { try { res.write(frame); } catch (_) {} }
  }

  closeAll() {
    for (const res of this.clients) { try { res.end(); } catch (_) {} }
    this.clients.clear();
  }
}
module.exports = { SSEHub };
