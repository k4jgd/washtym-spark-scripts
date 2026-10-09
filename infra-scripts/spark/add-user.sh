#!/usr/bin/env bash
#
# add-zeppelin-user.sh
#
# Adds (or updates) a user in Zeppelin's Shiro authentication file
# (conf/shiro.ini), under the [users] section, then restarts Zeppelin so
# the change takes effect immediately. Standalone and separate from
# setup-spark-standalone.sh by design — run this any time you need to
# add, update, or rotate a user's password, without touching Spark or
# re-provisioning anything.
#
# Usage:
#   sudo ./add-zeppelin-user.sh <username> <password> [role1,role2,...]
#
# Examples:
#   sudo ./add-zeppelin-user.sh admin  S3cur3P@ss        admin
#   sudo ./add-zeppelin-user.sh alice  anotherpassword    user1,user2
#
# Re-running with an existing username UPDATES that user's password/roles
# in place rather than creating a duplicate entry — this is also how you
# rotate a password later. Each run restarts Zeppelin (brief downtime for
# any open notebook sessions) so the new credentials are live right away.
#
# NOTE: This writes credentials in the plain-text format Zeppelin's
# default IniRealm expects (conf/shiro.ini). It does not enable password
# hashing or disable anonymous access on its own — see the printed notes
# at the end of this script for both of those, since neither is optional
# once real users are exposed on a network-reachable Zeppelin instance.
#
set -euo pipefail

ZEPPELIN_HOME="${ZEPPELIN_HOME:-/opt/zeppelin}"
SHIRO_INI="${ZEPPELIN_HOME}/conf/shiro.ini"
SHIRO_INI_TEMPLATE="${ZEPPELIN_HOME}/conf/shiro.ini.template"

if [ "$#" -lt 2 ]; then
  echo "Usage: $0 <username> <password> [role1,role2,...]" >&2
  exit 1
fi

USERNAME="$1"
PASSWORD="$2"
ROLES="${3:-}"

if [[ "${USERNAME}" =~ [[:space:]=,] ]]; then
  echo "ERROR: username must not contain spaces, '=', or ','." >&2
  exit 1
fi

# Build the credential line: "password" or "password, role1, role2"
if [ -n "${ROLES}" ]; then
  CRED_LINE="${PASSWORD}, ${ROLES//,/, }"
else
  CRED_LINE="${PASSWORD}"
fi

if [ ! -f "${SHIRO_INI}" ]; then
  if [ -f "${SHIRO_INI_TEMPLATE}" ]; then
    echo "==> No shiro.ini found — creating one from the bundled template."
    cp "${SHIRO_INI_TEMPLATE}" "${SHIRO_INI}"
  else
    echo "ERROR: Neither ${SHIRO_INI} nor ${SHIRO_INI_TEMPLATE} exists." >&2
    echo "       Check ZEPPELIN_HOME (currently ${ZEPPELIN_HOME})." >&2
    exit 1
  fi
fi

echo "==> Adding/updating user '${USERNAME}' in ${SHIRO_INI}"

awk -v user="${USERNAME}" -v cred="${CRED_LINE}" '
  BEGIN { in_users = 0; done = 0 }
  /^\[users\]/ {
    in_users = 1
    print
    next
  }
  in_users && /^\[/ && !/^\[users\]/ {
    if (!done) { print user " = " cred; done = 1 }
    in_users = 0
    print
    next
  }
  in_users && $0 ~ "^" user " *=" {
    print user " = " cred
    done = 1
    next
  }
  { print }
  END {
    if (in_users && !done) { print user " = " cred }
  }
' "${SHIRO_INI}" > "${SHIRO_INI}.tmp"

mv "${SHIRO_INI}.tmp" "${SHIRO_INI}"
chmod 600 "${SHIRO_INI}"   # credentials file — owner-read/write only

echo "==> Done. User '${USERNAME}' is set in shiro.ini."

ZEPPELIN_DAEMON="${ZEPPELIN_HOME}/bin/zeppelin-daemon.sh"
if [ -x "${ZEPPELIN_DAEMON}" ]; then
  echo "==> Restarting Zeppelin so this change takes effect"
  "${ZEPPELIN_DAEMON}" restart
else
  echo "WARNING: ${ZEPPELIN_DAEMON} not found or not executable — could not" >&2
  echo "         restart Zeppelin automatically. Restart it manually:" >&2
  echo "           sudo ${ZEPPELIN_DAEMON} restart" >&2
fi

echo ""
echo "Two related items worth checking, if not already done:"
echo "  1. Anonymous access: by default Zeppelin lets anyone in without"
echo "     logging in, which makes adding users pointless until this is"
echo "     disabled. Set zeppelin.anonymous.allowed=false in"
echo "     ${ZEPPELIN_HOME}/conf/zeppelin-site.xml (copy from the .template"
echo "     file there if zeppelin-site.xml doesn't exist yet)."
echo "  2. Password hashing: passwords in shiro.ini are stored in PLAIN"
echo "     TEXT under the default IniRealm. For anything beyond a personal"
echo "     dev box, configure a credentialsMatcher (e.g. sha256Matcher) in"
echo "     the [main] section of shiro.ini rather than leaving this as-is."
