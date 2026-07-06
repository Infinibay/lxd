// External-DB reachability + CREATE-privilege probe using the `pg` client.
//
// Reports EXACTLY which stage failed (DNS/connect → auth → CREATE privilege) so
// the operator can fix the right thing. A failed probe can be overridden in the
// wizard (they may be pointing at a DB that isn't up yet).

import pg from 'pg'

/**
 * @param {{host:string,port:number,user:string,password:string,database:string,ssl?:boolean}} cfg
 * @returns {Promise<{ok:boolean, stage:string, detail:string}>}
 */
export async function probeExternalDb (cfg) {
  const client = new pg.Client({
    host: cfg.host,
    port: cfg.port,
    user: cfg.user,
    password: cfg.password,
    database: cfg.database,
    ssl: cfg.ssl ? { rejectUnauthorized: false } : undefined,
    connectionTimeoutMillis: 8000,
    statement_timeout: 8000
  })

  try {
    try {
      await client.connect()
    } catch (err) {
      const msg = String(err?.message || err)
      // Distinguish auth failures from unreachable host for a useful message.
      const stage = /password|authentication|role .* does not exist/i.test(msg) ? 'auth' : 'connect'
      return { ok: false, stage, detail: msg }
    }

    try {
      await client.query('SELECT 1')
    } catch (err) {
      return { ok: false, stage: 'query', detail: String(err?.message || err) }
    }

    // Real create/drop is the most honest CREATE-privilege check.
    try {
      await client.query('CREATE TEMP TABLE _ib_probe (x int); DROP TABLE _ib_probe;')
    } catch (err) {
      return {
        ok: false,
        stage: 'create',
        detail: `Connected and authenticated, but the user lacks CREATE privilege on "${cfg.database}" ` +
                `(needed for the first-boot migration that creates ~70 tables): ${String(err?.message || err)}`
      }
    }

    return { ok: true, stage: 'ok', detail: `Reachable, authenticated, and CREATE-capable on "${cfg.database}".` }
  } finally {
    await client.end().catch(() => {})
  }
}

/** Assemble a Prisma-compatible connection string. */
export function buildDatabaseUrl ({ host, port, user, password, database, sslmode }) {
  const enc = encodeURIComponent
  const q = sslmode && sslmode !== 'disable' ? `?sslmode=${sslmode}` : ''
  return `postgresql://${enc(user)}:${enc(password)}@${host}:${port}/${enc(database)}${q}`
}
