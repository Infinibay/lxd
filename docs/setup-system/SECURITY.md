# Setup-system security posture

## App-level IP filtering is intentionally NOT used

Under the Docker/Podman dev topology every service binds `0.0.0.0` and is reached
through NAT. Inside a container, `req.ip` / `req.socket.remoteAddress` is the
**immediate TCP peer** — the Docker bridge gateway or the rootless-Podman
masquerade address, both RFC1918. So a naive "allow only RFC1918 sources"
middleware **passes every request** (including external clients NAT'd through the
gateway) — it fails open. Setting `trust proxy` is worse: it trusts a spoofable
`X-Forwarded-For`. There is no trusted reverse proxy in the stack to append a
real client IP. **Therefore there is no in-app source-IP check, by design.**

## What protects the two setup phases instead

- **Phase A (TUI, pre-boot)** collects the sensitive data (secrets, admin creds,
  DB creds) in the **host terminal**. There is **no network port** — nothing to
  reach from any network. This over-satisfies "LAN-only" for the part that
  matters most.
- **Phase B (`/setup`, post-boot)** is served by the frontend and protected by
  **auth + a time-box**: the setup mutations require an authenticated admin, and
  `setupMode` is open only while `AppSettings.setupCompleted === false` — it
  **closes forever** after `completeSetup`.

## Enforcing LAN-only at the host layer (recommended for non-loopback deploys)

Two independent, real controls:

1. **Bind published ports to an interface** instead of `0.0.0.0`. The setup TUI
   writes `PORT_BIND` (default `0.0.0.0`); set it to `127.0.0.1` (loopback only)
   or your LAN IP. Compose applies it to frontend (3000), backend (4000),
   postgres (5432) and the SPICE relay range (6100–6119).

2. **Host firewall.** The host sees the true L3 source before NAT, so this is the
   reliable place for an RFC1918 filter. A ready-to-run nftables snippet is
   provided:

   ```bash
   sudo lxd/provisioning/setup-firewall-lan-only.sh          # install
   sudo lxd/provisioning/setup-firewall-lan-only.sh --remove # uninstall
   ```

   It adds a dedicated `inet infinibay_lan_only` table (policy-accept) that, for
   the setup ports only, accepts RFC1918 + loopback + link-local and drops the
   rest — leaving all other traffic untouched and fully reversible.

## TLS

Everything is plain HTTP. For any exposure beyond a trusted LAN, terminate TLS at
a reverse proxy in front of the stack. The TUI warns about this when `PORT_BIND`
is left at `0.0.0.0`.

## What NOT to do

- ❌ In-app "reject non-RFC1918 `req.ip`" middleware (fails open under NAT).
- ❌ `app.set('trust proxy', true)` (spoofable XFF).
- ❌ Treat CORS/helmet as a LAN control (CORS restricts browser Origins, not source IPs).
- ❌ Bake a single literal LAN IP into compose (breaks on DHCP change) — use `PORT_BIND`.
