'use strict';
const path = require('path');
/** Reads + validates configuration from the environment exactly once. */
function loadConfig(env = process.env) {
  const port = parseInt(env.PORT || '8787', 10);
  if (!Number.isInteger(port) || port < 1 || port > 65535) {
    throw new Error(`Invalid PORT: ${env.PORT}`);
  }
  const num = (v, d) => { const n = parseInt(v, 10); return Number.isFinite(n) ? n : d; };
  const audioBatchMinutes = num(env.AUDIO_BATCH_MINUTES, 5);
  if (audioBatchMinutes < 1 || audioBatchMinutes > 60) throw new Error('AUDIO_BATCH_MINUTES must be between 1 and 60');
  return {
    port,
    ingestToken: env.INGEST_TOKEN || '',
    audioBatchMinutes,
    dataDir: path.resolve(env.DATA_DIR || path.join(__dirname, '..', 'data')),
    corsOrigin: env.CORS_ORIGIN || '*',
    maxAudioBytes: num(env.MAX_AUDIO_BYTES, 25 * 1024 * 1024),
    maxJsonBytes: num(env.MAX_JSON_BYTES, 64 * 1024),
    // retention: cap disk use per device
    retentionMaxSegments: num(env.RETENTION_MAX_SEGMENTS, 2000),
    retentionMaxAgeMs: num(env.RETENTION_MAX_AGE_MS, 24 * 60 * 60 * 1000),
    retentionMaxBytes: num(env.RETENTION_MAX_BYTES, 2 * 1024 * 1024 * 1024),
    // rate limit: token bucket per client key
    rateCapacity: num(env.RATE_CAPACITY, 120),      // burst
    rateRefillPerSec: num(env.RATE_REFILL_PER_SEC, 30),
    sseReplay: num(env.SSE_REPLAY, 50),             // events replayed on reconnect
  };
}
module.exports = { loadConfig };
