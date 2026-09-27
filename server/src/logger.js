'use strict';
/** Minimal structured logger (JSON lines). No deps. Level-filtered via LOG_LEVEL. */
const LEVELS = { error: 0, warn: 1, info: 2, debug: 3 };
const threshold = LEVELS[(process.env.LOG_LEVEL || 'info').toLowerCase()] ?? LEVELS.info;

function emit(level, msg, fields) {
  if (LEVELS[level] > threshold) return;
  const line = { ts: new Date().toISOString(), level, msg, ...(fields || {}) };
  const out = level === 'error' || level === 'warn' ? process.stderr : process.stdout;
  out.write(JSON.stringify(line) + '\n');
}
module.exports = {
  error: (m, f) => emit('error', m, f),
  warn: (m, f) => emit('warn', m, f),
  info: (m, f) => emit('info', m, f),
  debug: (m, f) => emit('debug', m, f),
};
