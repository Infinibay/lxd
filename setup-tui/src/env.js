// Minimal .env reader/writer for the setup TUI.
//
// Mirrors dev.sh `ensure_env_key` (grep-guarded append) but adds in-place
// overwrite — the TUI must UPDATE values the operator changes, not only append
// missing ones. Formatting stays shell-source-safe (KEY=value, one per line) so
// `set -a; . .env.docker` and `docker compose --env-file` both parse it.

import { readFileSync, writeFileSync, existsSync } from 'node:fs'

/** Parse a .env file into an ordered {key,value} view (comments/blanks ignored for lookup). */
export function readEnv (file) {
  if (!existsSync(file)) return {}
  const out = {}
  for (const line of readFileSync(file, 'utf8').split('\n')) {
    const m = line.match(/^\s*([A-Za-z_][A-Za-z0-9_]*)=(.*)$/)
    if (m) out[m[1]] = stripQuotes(m[2])
  }
  return out
}

function stripQuotes (v) {
  const t = v.trim()
  if ((t.startsWith('"') && t.endsWith('"')) || (t.startsWith("'") && t.endsWith("'"))) {
    return t.slice(1, -1)
  }
  return t
}

/** True when the value needs quoting to survive shell sourcing / compose parsing. */
function needsQuoting (value) {
  return /[\s#'"$`\\]/.test(value) || value === ''
}

function formatValue (value) {
  const s = String(value)
  if (!needsQuoting(s)) return s
  // Double-quote and escape embedded double quotes / backslashes / $ so neither
  // the shell nor compose mis-expands. Passwords with symbols are the main case.
  return '"' + s.replace(/([\\"$`])/g, '\\$1') + '"'
}

/**
 * Write KEY=value to `file`.
 *  - overwrite=false (default): append only if the key is absent (ensure_env_key semantics).
 *  - overwrite=true: replace an existing key's value in place, else append.
 * A one-line `# comment` is written above the key only when the key is first added.
 */
export function writeEnvKey (file, key, value, { overwrite = true, comment = '' } = {}) {
  const line = `${key}=${formatValue(value)}`
  let content = existsSync(file) ? readFileSync(file, 'utf8') : ''
  const re = new RegExp(`^\\s*${key}=.*$`, 'm')

  if (re.test(content)) {
    if (overwrite) {
      content = content.replace(re, line)
      writeFileSync(file, content)
    }
    return
  }

  if (content.length && !content.endsWith('\n')) content += '\n'
  if (comment) content += `\n# ${comment}\n`
  content += line + '\n'
  writeFileSync(file, content)
}

/** Remove a key entirely (used to drop DATABASE_URL when switching to managed DB). */
export function removeEnvKey (file, key) {
  if (!existsSync(file)) return
  const content = readFileSync(file, 'utf8')
  const re = new RegExp(`^\\s*${key}=.*\\n?`, 'm')
  if (re.test(content)) writeFileSync(file, content.replace(re, ''))
}

/** Apply a batch of {key,value,comment?,overwrite?} writes. */
export function writeEnv (file, entries) {
  for (const e of entries) {
    writeEnvKey(file, e.key, e.value, { overwrite: e.overwrite ?? true, comment: e.comment })
  }
}
