'use strict';
/*
 * Nexus Self-Monitor — transparent ingest server (entry point).
 * Modular, zero runtime dependencies. See docs/PROTOCOL.md.
 *
 * Transparency invariants (unchanged as features grow):
 *  - A session is refused unless the client asserts consentAcknowledged === true.
 *  - Every stored byte arrived from an explicit client request.
 *  - All data is listable (GET) and deletable (DELETE).
 */
const http = require('http');
const { loadConfig } = require('./src/config');
const logger = require('./src/logger');
const { Store } = require('./src/store');
const { SSEHub } = require('./src/sse');
const { createRateLimiter } = require('./src/rateLimit');
const { createHandler } = require('./src/router');

function createServer(overrides = {}) {
  const config = { ...loadConfig(), ...overrides };
  const store = new Store(config, logger);
  const sse = new SSEHub(config, logger);
  const rateLimit = createRateLimiter(config.rateCapacity, config.rateRefillPerSec);
  const handler = createHandler({ config, store, sse, rateLimit, logger });
  const server = http.createServer(handler);
  server.requestTimeout = 60_000;
  server.headersTimeout = 65_000;
  return { server, config, store, sse };
}

function start() {
  const { server, config, store, sse } = createServer();
  server.listen(config.port, '0.0.0.0', () => {
    logger.info('server.listening', {
      port: config.port,
      dashboard: `http://localhost:${config.port}/`,
      auth: config.ingestToken ? 'token-required' : 'OPEN',
      dataDir: config.dataDir,
    });
    if (!config.ingestToken) {
      logger.warn('server.open_auth', { hint: 'Set INGEST_TOKEN before exposing this server over a tunnel.' });
    }
  });

  let closing = false;
  const shutdown = (sig) => {
    if (closing) return; closing = true;
    logger.info('server.shutdown', { signal: sig });
    sse.closeAll();
    store.flush();
    server.close(() => process.exit(0));
    setTimeout(() => process.exit(0), 3000).unref();
  };
  process.on('SIGINT', () => shutdown('SIGINT'));
  process.on('SIGTERM', () => shutdown('SIGTERM'));
  process.on('uncaughtException', (e) => { logger.error('uncaught', { err: String(e.stack || e) }); });
  process.on('unhandledRejection', (e) => { logger.error('unhandled_rejection', { err: String(e) }); });
  return { server, config, store, sse };
}

if (require.main === module) start();
module.exports = { createServer, start };
