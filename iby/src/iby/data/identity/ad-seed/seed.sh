#!/bin/sh
# Seed the Samba AD test domain with the same two users + groups as the LDAP engine.
# Applied by `iby engine ad seed` (run inside the samba-dc container). Idempotent:
# every step tolerates "already exists". AD populates memberOf natively.
set -u

samba-tool user create alice 'Passw0rd!' \
  --given-name=Alice --surname=Infinibay --mail-address=alice@infinibay.lan 2>/dev/null \
  || echo "user alice already exists (ok)"

samba-tool user create bob 'Passw0rd!' \
  --given-name=Bob --surname=Infinibay --mail-address=bob@infinibay.lan 2>/dev/null \
  || echo "user bob already exists (ok)"

samba-tool group add infinibay-admins 2>/dev/null || echo "group infinibay-admins already exists (ok)"
samba-tool group add infinibay-users  2>/dev/null || echo "group infinibay-users already exists (ok)"

samba-tool group addmembers infinibay-admins alice     2>/dev/null || true
samba-tool group addmembers infinibay-users  alice,bob 2>/dev/null || true

echo "AD seed complete."
