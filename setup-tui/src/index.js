#!/usr/bin/env node
// Infinibay first-run bootstrap TUI (Phase A).
//
// Runs on the first `./dev.sh up`, BEFORE the stack boots. Collects everything
// that must exist as environment/secrets for the stack to come up healthily,
// writes .env.docker, and appends SETUP_DONE=1. dev.sh then continues to
// `docker/podman compose up` unchanged. This process NEVER touches the DB — the
// backend entrypoint runs migrate+seed.
//
// See lxd/docs/setup-system/01-tui-bootstrap.md.

import {
  intro, outro, text, password, select, confirm, note, log,
  spinner, isCancel, cancel, group
} from '@clack/prompts'
import { fileURLToPath } from 'node:url'
import { dirname, resolve, isAbsolute } from 'node:path'

import { readEnv, writeEnv, writeEnvKey, removeEnvKey } from './env.js'
import { ensureSecret } from './secrets.js'
import { probeExternalDb, buildDatabaseUrl } from './db-probe.js'
import { kvmPreflight, diskFree, humanBytes, verifySharedMount } from './preflight.js'

const __dirname = dirname(fileURLToPath(import.meta.url))

// ── args ─────────────────────────────────────────────────────────────────────
function parseArgs (argv) {
  const args = { reconfigure: false, envFile: null, hostIp: '' }
  for (let i = 0; i < argv.length; i++) {
    const a = argv[i]
    if (a === '--reconfigure') args.reconfigure = true
    else if (a === '--env-file') args.envFile = argv[++i]
    else if (a === '--host-ip') args.hostIp = argv[++i]
  }
  return args
}

const args = parseArgs(process.argv.slice(2))
// Default target: lxd/.env.docker (one level up from setup-tui/).
const ENV_FILE = args.envFile
  ? (isAbsolute(args.envFile) ? args.envFile : resolve(process.cwd(), args.envFile))
  : resolve(__dirname, '..', '..', '.env.docker')

function bail (value) {
  if (isCancel(value)) {
    cancel('Setup cancelled — nothing was written.')
    process.exit(1)
  }
  return value
}

// clack group() onCancel handler: a cancelled field aborts the whole wizard.
function onCancel () {
  cancel('Setup cancelled — nothing was written.')
  process.exit(1)
}

function isStrongEnough (pw, min = 12) {
  if (!pw || pw.length < min) return `Use at least ${min} characters.`
  return undefined
}

async function main () {
  const env = readEnv(ENV_FILE)

  intro('Infinibay — first-run setup (Phase A)')
  note(
    [
      `This configures the DEV stack and writes:\n  ${ENV_FILE}`,
      'The LXD self-hosting path (.env + values.yml) is separate — see run.sh.',
      args.reconfigure ? '\nReconfigure mode: existing secrets are preserved.' : ''
    ].filter(Boolean).join('\n'),
    'About'
  )

  // Collected values written at the end (so a mid-wizard cancel writes nothing).
  const out = [] // { key, value, comment? }
  const put = (key, value, comment) => out.push({ key, value, comment })
  const secretReveals = [] // { label, value } for the reveal-once step

  // ── 4.2 Database ─────────────────────────────────────────────────────────
  // Deferred file mutation: DATABASE_URL is only dropped in the final write batch
  // (managed DB) so a mid-wizard cancel leaves .env.docker untouched.
  let dropDatabaseUrl = false
  const dbMode = bail(await select({
    message: 'Database',
    options: [
      { value: 'managed', label: 'Managed (recommended)', hint: 'compose runs postgres:16' },
      { value: 'external', label: 'External PostgreSQL', hint: 'you already run a Postgres' }
    ],
    initialValue: env.DATABASE_URL ? 'external' : 'managed'
  }))

  if (dbMode === 'managed') {
    const pg = bail(await group({
      user: () => text({ message: 'POSTGRES_USER', initialValue: env.POSTGRES_USER || 'infinibay' }),
      db: () => text({ message: 'POSTGRES_DB', initialValue: env.POSTGRES_DB || 'infinibay' }),
      port: () => text({ message: 'POSTGRES_PORT', initialValue: env.POSTGRES_PORT || '5432', validate: (v) => (/^\d+$/.test(v) ? undefined : 'numeric port') })
    }, { onCancel }))

    const pgPass = ensureSecret(env.POSTGRES_PASSWORD, 24)
    put('POSTGRES_USER', pg.user)
    put('POSTGRES_DB', pg.db)
    put('POSTGRES_PORT', pg.port)
    put('POSTGRES_PASSWORD', pgPass.value, 'managed DB password (generated once)')
    if (pgPass.generated) secretReveals.push({ label: 'POSTGRES_PASSWORD', value: pgPass.value })
    // Managed DB: compose derives DATABASE_URL from POSTGRES_*; drop any stale
    // external URL (deferred to the final write so a mid-wizard cancel changes
    // nothing) and select the managed-db compose profile.
    dropDatabaseUrl = true
    put('COMPOSE_PROFILES', 'managed-db', 'compose profiles active (managed-db → run bundled postgres)')
  } else {
    note(
      [
        '• PostgreSQL only (the Prisma schema is pg-specific); recommend ≥ 14.',
        '• Must be reachable FROM INSIDE the backend container. If the DB is on',
        '  this host, that is host.docker.internal (or the LAN IP), NOT localhost.',
        '• The user needs CREATE privileges — first boot creates ~70 tables.',
        '• For remote DBs, prefer sslmode=require.'
      ].join('\n'),
      'External DB caveats'
    )
    let confirmed = false
    let url = ''
    let extConn = null
    while (!confirmed) {
      const ext = bail(await group({
        host: () => text({ message: 'DB host', placeholder: 'host.docker.internal', validate: (v) => (v ? undefined : 'required') }),
        port: () => text({ message: 'DB port', initialValue: '5432', validate: (v) => (/^\d+$/.test(v) ? undefined : 'numeric port') }),
        user: () => text({ message: 'DB user', validate: (v) => (v ? undefined : 'required') }),
        pass: () => password({ message: 'DB password' }),
        database: () => text({ message: 'DB name', validate: (v) => (v ? undefined : 'required') }),
        sslmode: () => select({ message: 'sslmode', options: [{ value: 'disable', label: 'disable' }, { value: 'require', label: 'require' }], initialValue: 'disable' })
      }, { onCancel }))

      url = buildDatabaseUrl({ host: ext.host, port: ext.port, user: ext.user, password: ext.pass, database: ext.database, sslmode: ext.sslmode })
      extConn = ext

      const s = spinner()
      s.start('Probing the database (connectivity + CREATE privilege)…')
      const probe = await probeExternalDb({ host: ext.host, port: Number(ext.port), user: ext.user, password: ext.pass, database: ext.database, ssl: ext.sslmode === 'require' })
      s.stop(probe.ok ? 'Probe passed ✓' : `Probe failed at stage: ${probe.stage}`)

      if (probe.ok) {
        note(probe.detail, 'Database')
        confirmed = true
      } else {
        note(probe.detail, `Probe failed (${probe.stage})`)
        note('If the probe ran on the host but the backend runs in a container, a localhost DB may be host.docker.internal from the container — the check may differ from runtime.', 'Reachability note')
        const choice = bail(await select({
          message: 'The probe failed. What now?',
          options: [
            { value: 'retry', label: 'Re-enter connection details' },
            { value: 'override', label: 'Continue anyway (I understand)', hint: 'e.g. the DB is not up yet' }
          ],
          initialValue: 'retry'
        }))
        if (choice === 'override') confirmed = true
      }
    }
    put('DATABASE_URL', url, 'external PostgreSQL connection string')
    // External DB: drop the bundled postgres by clearing compose profiles.
    put('COMPOSE_PROFILES', '', 'compose profiles active (empty → external DB, bundled postgres excluded)')
    // Point the backend entrypoint's pg_isready wait at the EXTERNAL DB (compose
    // defaults PG* to the bundled postgres service, which is excluded here).
    put('PGHOST', extConn.host, 'external DB host for the entrypoint readiness wait')
    put('PGPORT', extConn.port)
    put('PGUSER', extConn.user)
    put('PGPASSWORD', extConn.pass)
    put('PGDATABASE', extConn.database)
  }

  // ── secrets (generate once, never rewrite a real value) ───────────────────
  const tokenKey = ensureSecret(env.TOKENKEY, 40)
  const hmac = ensureSecret(env.INFINISERVICE_HMAC_MASTER_SECRET, 44)
  put('TOKENKEY', tokenKey.value, 'JWT signing secret (generated once — rotating invalidates all sessions)')
  put('INFINISERVICE_HMAC_MASTER_SECRET', hmac.value, 'agent command-signing master secret (generated once — rotating breaks all guest agents)')
  if (tokenKey.generated) secretReveals.push({ label: 'TOKENKEY', value: tokenKey.value })
  if (hmac.generated) secretReveals.push({ label: 'INFINISERVICE_HMAC_MASTER_SECRET', value: hmac.value })
  log.info(`TOKENKEY: ${tokenKey.generated ? 'generated' : 'already set ✓'} · HMAC master secret: ${hmac.generated ? 'generated' : 'already set ✓'}`)

  // ── 4.4 Super admin ───────────────────────────────────────────────────────
  const adminMode = bail(await select({
    message: 'Super administrator',
    options: [
      { value: 'real', label: 'Set real credentials (recommended)' },
      { value: 'dev', label: 'Development mode', hint: 'admin@example.com / password — INSECURE' }
    ],
    initialValue: 'real'
  }))

  if (adminMode === 'real') {
    const admin = bail(await group({
      email: () => text({ message: 'Admin email', initialValue: env.DEFAULT_ADMIN_EMAIL && env.DEFAULT_ADMIN_EMAIL !== 'admin@example.com' ? env.DEFAULT_ADMIN_EMAIL : '', validate: (v) => (/.+@.+\..+/.test(v) ? undefined : 'valid email required') }),
      pass: () => password({ message: 'Admin password (≥ 12 chars)', validate: (v) => isStrongEnough(v, 12) }),
      confirm: () => password({ message: 'Confirm admin password' })
    }, { onCancel }))
    if (admin.pass !== admin.confirm) {
      cancel('Passwords did not match — nothing was written. Re-run setup.')
      process.exit(1)
    }
    put('DEFAULT_ADMIN_EMAIL', admin.email)
    put('DEFAULT_ADMIN_PASSWORD', admin.pass, 'admin bootstrap password (seed creates the admin from this)')
    // Real creds → not dev mode. Clear the marker so /setup does not force a change.
    put('INFINIBAY_DEV_MODE_ADMIN', '0')
    secretReveals.push({ label: 'Admin password', value: admin.pass })
  } else {
    note('The admin will be admin@example.com / password. This is INSECURE — /setup will force a password change on first login before setup can be completed.', '⚠  Development mode')
    put('DEFAULT_ADMIN_EMAIL', 'admin@example.com')
    put('DEFAULT_ADMIN_PASSWORD', 'password')
    put('INFINIBAY_DEV_MODE_ADMIN', '1', 'seed sets AppSettings.devModeAdmin=true → /setup forces a password change')
  }

  // ── 4.5 Network & exposure ────────────────────────────────────────────────
  const hostIp = bail(await text({
    message: 'HOST_IP (LAN IP advertised for remote access; blank = auto/localhost-only)',
    initialValue: env.HOST_IP || args.hostIp || ''
  }))
  if (hostIp) put('HOST_IP', hostIp)

  const portBind = bail(await select({
    message: 'Bind published ports to which interface? (the real LAN-only control)',
    options: [
      { value: '0.0.0.0', label: 'All interfaces (0.0.0.0)', hint: 'default' },
      { value: '127.0.0.1', label: 'Loopback only (127.0.0.1)', hint: 'admin via host/SSH tunnel' },
      ...(hostIp ? [{ value: hostIp, label: `LAN NIC only (${hostIp})` }] : [])
    ],
    initialValue: env.PORT_BIND || '0.0.0.0'
  }))
  put('PORT_BIND', portBind, 'host interface published ports bind to (LAN-only control; compose uses ${PORT_BIND}:PORT:PORT)')
  if (portBind === '0.0.0.0') {
    note(
      'Everything is served over PLAIN HTTP (no TLS). This dev stack has no in-app\n' +
      'IP filtering — under container NAT the app cannot see the real client IP, so\n' +
      'that would fail open. For anything beyond your LAN, put a TLS reverse proxy in\n' +
      'front, restrict PORT_BIND to 127.0.0.1/your LAN IP, and/or apply the host\n' +
      'firewall snippet in docs/setup-system/SECURITY.md.',
      '⚠  Exposure / TLS'
    )
  }

  const ports = bail(await group({
    backend: () => text({ message: 'BACKEND_PORT', initialValue: env.BACKEND_PORT || '4000', validate: numPort }),
    frontend: () => text({ message: 'FRONTEND_PORT', initialValue: env.FRONTEND_PORT || '3000', validate: numPort })
  }, { onCancel }))
  put('BACKEND_PORT', ports.backend)
  put('FRONTEND_PORT', ports.frontend)

  // ── 4.6 Storage ───────────────────────────────────────────────────────────
  const diskDir = bail(await text({ message: 'INFINIZATION_DISK_DIR (where qcow2 disks live)', initialValue: env.INFINIZATION_DISK_DIR || '/var/lib/infinization/disks' }))
  put('INFINIZATION_DISK_DIR', diskDir)
  const free = diskFree(diskDir)
  if (free.bytes !== undefined) {
    log[free.bytes < 20 * 1024 ** 3 ? 'warn' : 'info'](`Free space on ${free.checkedPath}: ${humanBytes(free.bytes)}${free.bytes < 20 * 1024 ** 3 ? ' — low for VM disks' : ''}`)
  }
  put('INFINIBAY_BASE_DIR', env.INFINIBAY_BASE_DIR || '/opt/infinibay')

  const multiNode = bail(await confirm({ message: 'Multi-node / shared storage? (single-node dev: No)', initialValue: false }))
  if (multiNode) {
    const backend = bail(await select({
      message: 'Storage backend',
      options: [
        { value: 'local', label: 'Local (per-node disks)', hint: 'migration copies the disk' },
        { value: 'shared-mount', label: 'Shared mount (NFS/iSCSI/SAN)', hint: 'migration skips the copy' }
      ],
      initialValue: env.INFINIBAY_STORAGE_BACKEND || 'local'
    }))
    put('INFINIBAY_STORAGE_BACKEND', backend)
    if (backend === 'shared-mount') {
      const check = verifySharedMount(diskDir)
      log[check.ok ? 'info' : 'warn'](check.detail)
      let write = check.ok
      if (!check.ok) {
        write = bail(await confirm({ message: 'Shared-storage check failed. Declare shared storage anyway?', initialValue: false }))
      }
      if (write) {
        put('INFINIBAY_SHARED_STORAGE', 'true', 'legacy shared-storage flag (kept in sync with STORAGE_BACKEND)')
      } else {
        // Fall back to local if they decline to declare shared storage.
        out[out.length - 1].value = 'local'
      }
    } else {
      put('INFINIBAY_SHARED_STORAGE', 'false')
    }
  } else {
    put('INFINIBAY_STORAGE_BACKEND', 'local')
  }

  // ── 4.7 Runtime toggles & KVM preflight ───────────────────────────────────
  const kvm = kvmPreflight()
  log[kvm.ok ? 'info' : 'warn'](kvm.detail)
  if (!kvm.ok) {
    const proceed = bail(await confirm({ message: 'KVM unavailable → control-plane-only (no VM create/start). Continue?', initialValue: true }))
    if (!proceed) { cancel('Setup cancelled.'); process.exit(1) }
    put('KVM', 'off', 'no /dev/kvm or CPU virt — control-plane-only')
  }

  put('NODE_ENV', env.NODE_ENV || 'development')
  put('LOG_LEVEL', env.LOG_LEVEL || 'info')
  put('RUN_SEED', 'true')
  put('BCRYPT_ROUNDS', env.BCRYPT_ROUNDS || '10')

  // ── 4.8 Review & Deploy ───────────────────────────────────────────────────
  const summary = out
    .filter((e) => !isSecretKey(e.key))
    .map((e) => `  ${e.key}=${e.value}`)
    .join('\n')
  note(`${summary}\n  (secrets masked: ${out.filter((e) => isSecretKey(e.key)).map((e) => e.key).join(', ') || 'none'})`, 'Will write to .env.docker')

  if (secretReveals.length) {
    const reveal = bail(await confirm({ message: 'Reveal generated secrets / admin password ONCE so you can save them?', initialValue: true }))
    if (reveal) {
      note(secretReveals.map((s) => `  ${s.label} = ${s.value}`).join('\n'), '🔑 Save these now — they are masked afterwards')
    }
  }

  const deploy = bail(await confirm({ message: 'Write configuration and deploy?', initialValue: true }))
  if (!deploy) { cancel('Setup cancelled — nothing was written.'); process.exit(1) }

  writeEnv(ENV_FILE, out)
  if (dropDatabaseUrl) removeEnvKey(ENV_FILE, 'DATABASE_URL')
  writeEnvKey(ENV_FILE, 'SETUP_DONE', '1', { overwrite: true, comment: 'first-run setup completed (delete this line or run ./dev.sh reconfigure to re-run)' })

  outro(`Configuration written to ${ENV_FILE}. Bringing the stack up…`)
}

function numPort (v) { return /^\d+$/.test(v) ? undefined : 'numeric port' }
function isSecretKey (key) {
  return ['TOKENKEY', 'INFINISERVICE_HMAC_MASTER_SECRET', 'POSTGRES_PASSWORD', 'DEFAULT_ADMIN_PASSWORD', 'INFINIBAY_CLUSTER_TOKEN', 'DATABASE_URL', 'PGPASSWORD'].includes(key)
}

main().catch((err) => {
  cancel(`Setup failed: ${err?.message || err}`)
  process.exit(1)
})
