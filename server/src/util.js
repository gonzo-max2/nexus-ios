'use strict';
/** Shared validation helpers. */
function safeSegment(s) {
  return String(s == null ? '' : s).replace(/[^A-Za-z0-9_.-]/g, '_').slice(0, 128);
}
function isFiniteNum(n) { return typeof n === 'number' && Number.isFinite(n); }
function validLat(n) { return isFiniteNum(n) && n >= -90 && n <= 90; }
function validLng(n) { return isFiniteNum(n) && n >= -180 && n <= 180; }
function clampNum(n, lo, hi) { return Math.max(lo, Math.min(hi, n)); }
module.exports = { safeSegment, isFiniteNum, validLat, validLng, clampNum };
