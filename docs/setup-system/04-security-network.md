# 04 — Security & Network (LAN-only, done right)

The user's goal — the first-run setup must not be usable from outside the local network — is
correct and kept. What changes is the **mechanism**: enforce it at the host/network layer, and lean
on the TUI removing exposure entirely for the sensitive half. **Never** use an in-app source-IP
check under this container topology.

Grounding: [`05-grounding-reference.md`](./05-grounding-reference.md#network--exposure).

---

## 1. The gotcha (why the obvious approach fails)

Every service binds `0.0.0.0` today (backend `httpServer.listen({host:'0.0.0.0'})`; Next `-H ::`;
compose publishes ports with no host-IP prefix). There is **no `trust proxy`** set.

Inside a container, `req.ip` / `req.socket.remoteAddress` is the **immediate TCP peer** — under
Docker port-publish that's the **Docker bridge gateway** (an RFC1918 address like `172.x`/`10.x`),
and under **rootless Podman** (the documented dev target, slirp4netns/pasta) it's the NAT masquerade
address. So:
- A naive "allow RFC1918" middleware **passes every request** — including real external clients
  NAT'd through the gateway → it **fails open** (security theater).
- Setting `app.set('trust proxy', true)` is worse: it trusts a client-supplied `X-Forwarded-For`,
  which is trivially spoofable → bypass.

**Conclusion:** the container cannot see the real client IP. App-level IP filtering is off the table
unless a real reverse proxy that appends a trusted XFF is placed in front (not in the current stack).

---

## 2. What we do instead

### 2.1 Sensitive half → TUI → no exposure at all

Phase A (secrets, admin creation, DB creds) runs in the **host terminal**. There is **no port**,
so there is nothing to reach from any network. This over-satisfies "LAN-only" for the part that
matters most. (This is a core reason the design is a hybrid.)

### 2.2 `/setup` half → auth + time-box

Phase B is served by the frontend (already LAN-exposed on :3000 by design). Protect it by:
- **Auth:** setup mutations already require an authenticated privileged user (the RBAC `@Can`
  gates); while `setupMode` is open, only the first admin (who just logged in) drives it.
- **Time-box:** `setupMode` is open only while `AppSettings.setupCompleted === false` and **closes
  forever** after `completeSetup`. Bounding exposure in *time* matters more than source IP for a
  first-run flow. Keep the `setupMode` scope minimal (only setup resolvers).

### 2.3 Optional hard network boundary (host layer)

If a real network restriction is wanted on top:
1. **Bind published ports to the intended interface**, not `0.0.0.0`. In compose, prefix mappings
   with a host IP via a `PORT_BIND` var the TUI writes: `127.0.0.1` (loopback-only; admin uses the
   host or an SSH tunnel) or `${HOST_IP}` (pin to the LAN NIC). Apply to **frontend (3000) and
   backend (4000)**, and lock down **postgres (5432)** and the **SPICE relay range (6100–6119)** too
   — those are also published on `0.0.0.0` today.
2. **Host firewall** (nftables/ufw) accepting the setup ports only from RFC1918 + loopback +
   link-local (`10/8, 172.16/12, 192.168/16, 127/8, 169.254/16, fc00::/7, ::1, fe80::/10`) and
   dropping the rest. The **host** sees the true L3 source before NAT, so this is the reliable place
   for the RFC1918 filter. infinization already manages nftables — reuse that in-house tooling.

This is optional for dev; recommend it for any non-loopback deployment.

---

## 3. Compose changes

- **External-DB profile:** guard the `postgres` service with `profiles: ["managed-db"]` (or similar)
  so the TUI can exclude it (via `COMPOSE_PROFILES`) when the operator chose an external DB.
- **Host-IP port binding:** parameterize the host side of port mappings with `${PORT_BIND:-0.0.0.0}`
  (e.g. `"${PORT_BIND:-0.0.0.0}:${FRONTEND_PORT:-3000}:3000"`), written by the TUI. Verify Docker
  **and** Podman accept the syntax in this repo's compose flavor.
- Do the same for `docker-compose.kvm.yml` / `.cluster.yml` where relevant.

---

## 4. What NOT to do (explicit)

- ❌ In-app "reject non-RFC1918 `req.ip`" middleware (fails open under NAT).
- ❌ `app.set('trust proxy', true)` (spoofable XFF).
- ❌ Rely on CORS/helmet as a LAN control — CORS restricts browser Origins, not source IPs.
- ❌ Bind a single literal LAN IP into compose that then breaks on DHCP change — prefer the
  `PORT_BIND` var (re-derivable via `detect_host_ip`) or loopback.

---

## 5. Checklist

- [ ] TUI: `PORT_BIND` prompt (0.0.0.0 / 127.0.0.1 / ${HOST_IP}) written to `.env.docker`.
- [ ] Compose: `${PORT_BIND:-0.0.0.0}` prefix on 3000/4000/5432/6100-6119 mappings; `managed-db` profile on `postgres`.
- [ ] Backend: `setupMode` reads `AppSettings.setupCompleted`; scope limited to setup resolvers; closes on `completeSetup`.
- [ ] Frontend: `/setup` reachable pre-login while open; redirect logic; closed after completion.
- [ ] (Optional) nftables/ufw snippet accepting setup ports from RFC1918+loopback only; document it.
- [ ] Docs: state clearly that app-level IP filtering is intentionally NOT used and why.
