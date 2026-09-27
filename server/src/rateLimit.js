'use strict';
/** Token-bucket rate limiter keyed by an arbitrary string (IP or device id). */
function createRateLimiter(capacity, refillPerSec) {
  const buckets = new Map(); // key -> { tokens, ts }
  // periodic sweep to bound memory
  const sweep = setInterval(() => {
    const now = Date.now();
    for (const [k, b] of buckets) if (now - b.ts > 5 * 60 * 1000) buckets.delete(k);
  }, 60 * 1000);
  sweep.unref?.();

  return function allow(key) {
    const now = Date.now();
    let b = buckets.get(key);
    if (!b) { b = { tokens: capacity, ts: now }; buckets.set(key, b); }
    const elapsed = (now - b.ts) / 1000;
    b.tokens = Math.min(capacity, b.tokens + elapsed * refillPerSec);
    b.ts = now;
    if (b.tokens < 1) return false;
    b.tokens -= 1;
    return true;
  };
}
module.exports = { createRateLimiter };
