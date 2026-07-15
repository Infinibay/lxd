#!/bin/sh
# Enable the memberOf overlay so group membership is reflected on user entries as a
# `memberOf` attribute — the backend's group→role mapping reads entry.memberOf
# (IdentityProviderService.resolveRoleFromGroups). Without this, every synced user
# stays USER regardless of their groups.
#
# Two gotchas a static LDIF cannot handle, and why this is a script:
#   1. The data DB's config DN ({N}mdb) varies by image — we DISCOVER it, not hardcode
#      olcDatabase={1}mdb (which silently fails on images that number it differently).
#   2. The overlay does NOT backfill pre-existing memberships. So after enabling it we
#      delete + recreate the groups, making the membership writes flow through the live
#      overlay and land memberOf onto alice/bob.
#
# Run inside the openldap container by `iby engine ldap up|seed --memberof`.
# Idempotent: re-running is safe (module/overlay "already exists" is tolerated).
set -u

BASE="dc=infinibay,dc=local"
ADMIN="cn=admin,${BASE}"
PW="admin"

log() { echo "[memberof] $*"; }

# 1) discover the data (mdb) database DN under cn=config.
DB_DN=$(ldapsearch -Q -Y EXTERNAL -H ldapi:/// -b cn=config -LLL \
          '(objectClass=olcMdbConfig)' dn 2>/dev/null | sed -n 's/^dn: //p' | head -1)
if [ -z "${DB_DN}" ]; then
  log "could not locate the mdb database under cn=config — is slapd up? aborting."
  exit 1
fi
log "data database: ${DB_DN}"

# 2) load the memberof module (idempotent: rc 20 = already loaded).
ldapadd -Q -Y EXTERNAL -H ldapi:/// >/dev/null 2>&1 <<EOF
dn: cn=module{0},cn=config
changetype: modify
add: olcModuleLoad
olcModuleLoad: memberof
EOF
log "memberof module loaded (or already present)."

# 3) attach the overlay to the discovered DB (idempotent: rc 68 = already exists).
ldapadd -Q -Y EXTERNAL -H ldapi:/// >/dev/null 2>&1 <<EOF
dn: olcOverlay=memberof,${DB_DN}
objectClass: olcOverlayConfig
objectClass: olcMemberOf
olcOverlay: memberof
olcMemberOfRefInt: TRUE
olcMemberOfGroupOC: groupOfNames
olcMemberOfMemberAD: member
olcMemberOfMemberOfAD: memberOf
EOF
log "memberof overlay attached (or already present)."

# 4) (re)create the groups so membership flows through the overlay. Pre-existing groups
#    (from 01-seed.ldif) were written before the overlay was live, so their memberOf was
#    never populated — recreate them now.
ldapdelete -x -D "${ADMIN}" -w "${PW}" \
  "cn=infinibay-admins,ou=groups,${BASE}" \
  "cn=infinibay-users,ou=groups,${BASE}" >/dev/null 2>&1 || true

if ldapadd -x -D "${ADMIN}" -w "${PW}" >/dev/null 2>&1 <<EOF
dn: cn=infinibay-admins,ou=groups,${BASE}
objectClass: groupOfNames
cn: infinibay-admins
member: uid=alice,ou=people,${BASE}

dn: cn=infinibay-users,ou=groups,${BASE}
objectClass: groupOfNames
cn: infinibay-users
member: uid=alice,ou=people,${BASE}
member: uid=bob,ou=people,${BASE}
EOF
then
  log "groups recreated — memberOf now on alice (admins+users) and bob (users)."
else
  log "group recreate failed — are alice/bob seeded? run \`iby engine ldap seed\` first."
  exit 1
fi
