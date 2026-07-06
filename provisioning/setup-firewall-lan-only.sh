#!/usr/bin/env bash
# Optional host firewall: restrict Infinibay's published ports to the local
# network only. This is the RELIABLE place to enforce "LAN-only" — the HOST sees
# the true L3 source address BEFORE Docker/Podman NAT, whereas the containers
# see only the NAT gateway (an RFC1918 address), so an in-app IP check would fail
# open. See docs/setup-system/SECURITY.md.
#
# Adds a dedicated nftables table (inet infinibay_lan_only) with a policy-accept
# input chain that, ONLY for the setup ports, accepts RFC1918 + loopback +
# link-local sources and drops the rest. It does not touch any other traffic and
# is fully reversible.
#
# Usage:
#   sudo ./setup-firewall-lan-only.sh            # install
#   sudo ./setup-firewall-lan-only.sh --remove   # uninstall
#   PORTS="3000,4000,5432,6100-6119" sudo ./setup-firewall-lan-only.sh
set -euo pipefail

TABLE="infinibay_lan_only"
PORTS="${PORTS:-3000,4000,5432,6100-6119}"

if ! command -v nft >/dev/null 2>&1; then
  echo "nftables (nft) not found. Install it: sudo apt-get install -y nftables" >&2
  exit 1
fi

if [ "${1:-}" = "--remove" ]; then
  nft delete table inet "$TABLE" 2>/dev/null && echo "removed nft table inet $TABLE" || echo "nothing to remove"
  exit 0
fi

# Normalize the comma list into nft set elements ("6100-6119" ranges are kept).
elems="$(printf '%s' "$PORTS" | tr ',' ' ')"
set_elems=""
for p in $elems; do set_elems="${set_elems:+$set_elems, }$p"; done

nft -f - <<EOF
table inet $TABLE {
  set lan4 { type ipv4_addr; flags interval; elements = { 10.0.0.0/8, 172.16.0.0/12, 192.168.0.0/16, 127.0.0.0/8, 169.254.0.0/16 } }
  set lan6 { type ipv6_addr; flags interval; elements = { ::1, fc00::/7, fe80::/10 } }
  set setup_ports { type inet_service; flags interval; elements = { $set_elems } }

  chain input {
    # priority -10 runs before the usual filter hooks; policy accept means this
    # chain ONLY affects the setup ports and leaves everything else untouched.
    type filter hook input priority -10; policy accept;
    tcp dport @setup_ports ip  saddr @lan4 accept
    tcp dport @setup_ports ip6 saddr @lan6 accept
    tcp dport @setup_ports drop
  }
}
EOF

echo "installed nft table inet $TABLE — ports {$PORTS} now reachable from RFC1918/loopback/link-local only."
echo "remove with: sudo $0 --remove"
