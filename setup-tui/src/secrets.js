// Secret generation with the "generate once, never rewrite" rule.
//
// Rotating TOKENKEY invalidates every session; rotating
// INFINISERVICE_HMAC_MASTER_SECRET breaks EVERY existing guest agent (per-VM keys
// derive from it → guests reject all commands). So a real (non-placeholder) value
// is NEVER overwritten, even on `./dev.sh reconfigure`.

import { randomBytes } from 'node:crypto'

// Placeholders shipped in .env.docker.example / considered "not yet set".
const PLACEHOLDERS = new Set([
  '',
  'changeme',
  'change-me',
  'dev-insecure-change-me',
  'dev-insecure-cluster-token',
  'infinibay' // the example POSTGRES_PASSWORD default
])

/** True when `value` is unset or a known insecure placeholder → safe to generate over. */
export function isPlaceholder (value) {
  if (value === undefined || value === null) return true
  return PLACEHOLDERS.has(String(value).trim())
}

/** URL-safe random secret of ~`bytes` entropy. */
export function generateSecret (bytes = 32) {
  return randomBytes(bytes).toString('base64url')
}

/**
 * Return the existing secret if it is real, otherwise a freshly generated one.
 * `{ value, generated }` — `generated=false` means "already set, left untouched".
 */
export function ensureSecret (existing, bytes = 32) {
  if (!isPlaceholder(existing)) return { value: existing, generated: false }
  return { value: generateSecret(bytes), generated: true }
}
