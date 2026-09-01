#!/usr/bin/env bash
# A1 — team access on the inherited server.
# Idempotent: safe to re-run. Run as root on the VPS.
#
#   sudo bash setup-users.sh
#
# Design notes (the reasoning is in ../ANSWERS.md):
#   * "others" gets nothing anywhere under /srv/abdur/app. Every cross-team read is an
#     explicit ACL entry, so `getfacl` documents the access model.
#   * abdur_dan reads via the `abdur_auditor` group ACL, never via o+r.
#   * setgid on every directory so new files inherit the owning group.
#   * the secrets directory gets an ACL; the secrets FILE deliberately does not.

set -euo pipefail

APP=/srv/abdur/app
PREFIX=abdur

# ---------------------------------------------------------------------------
# SHARED SERVER GUARD
#
# This VPS is shared with other students. Unprefixed `alice`, `bob`, `carol`,
# `dan`, `devs`, `ops`, `auditor` and /srv/app ALREADY EXIST and belong to
# somebody else. An earlier version of this script called `usermod -g` on
# those names, which would have silently rewritten another student's work.
#
# Everything below is namespaced with $PREFIX. This guard refuses to run at all
# if any unprefixed name has crept back into the script.
# ---------------------------------------------------------------------------
# The pattern lives in a variable and its own line carries a GUARD_SELF marker,
# so the check does not match itself and report a false positive.
BAD_RE='(^|[^_a-z])(alice|bob|carol|dan|devs|ops|auditor)([^_a-z]|$)'   # GUARD_SELF
if grep -nE "$BAD_RE" "$0" | grep -v GUARD_SELF | grep -v '^[0-9]*:#' | grep -q .; then
  echo "REFUSING TO RUN: an unprefixed shared username appears in this script." >&2
  echo "Every identity must be ${PREFIX}_<name>. Offending lines:" >&2
  grep -nE "$BAD_RE" "$0" | grep -v GUARD_SELF | grep -v '^[0-9]*:#' >&2
  exit 1
fi

if [ -e /srv/app ] && [ ! -L /srv/app ]; then
  echo "note: /srv/app exists and belongs to another student -- not touching it."
fi
BACKUP_FILES=(backup1.tar backup2.tar backup3.tar)

need() { command -v "$1" >/dev/null || { echo "missing: $1"; exit 1; }; }
need setfacl
need chattr

echo "== groups =="
for g in abdur_devs abdur_ops abdur_auditor; do
  getent group "$g" >/dev/null || groupadd "$g"
  echo "  group $g ok"
done

echo "== users =="
# abdur_alice/abdur_bob: abdur_devs. abdur_carol: primary abdur_ops, secondary abdur_devs (the brief says she can do
# "everything abdur_devs can do", so she is genuinely a member of abdur_devs). abdur_dan: abdur_auditor.
add_user() { # name primary_group extra_groups
  local u=$1 pg=$2 extra=${3:-}
  if ! id -u "$u" >/dev/null 2>&1; then
    useradd -m -s /bin/bash -g "$pg" "$u"
    passwd -l "$u" >/dev/null      # no password login; SSH keys only
  else
    usermod -g "$pg" "$u"
  fi
  [ -n "$extra" ] && usermod -aG "$extra" "$u"
  echo "  $(id "$u")"
}
add_user abdur_alice abdur_devs
add_user abdur_bob   abdur_devs
add_user abdur_carol abdur_ops   abdur_devs
add_user abdur_dan   abdur_auditor

# The service account. Cannot log in, owns nothing it does not need.
id -u abdur_myappuser >/dev/null 2>&1 || \
  useradd --system --no-create-home --shell /usr/sbin/nologin abdur_myappuser
echo "  $(id abdur_myappuser)"

echo "== directories =="
# /srv/abdur is mine; /srv/app, /srv/ashik and /srv/badhon are not.
mkdir -p /srv/abdur
chown root:root /srv/abdur
chmod 0755 /srv/abdur
mkdir -p "$APP"/{src,config,secrets,logs,backups}

# /srv/abdur/app itself is only a doorway: everyone may traverse it, nobody may write.
chown root:root "$APP"
chmod 0755 "$APP"

# --- src: abdur_devs (and abdur_carol, who is in abdur_devs) read+write. -----------------------
chown -R root:abdur_devs "$APP/src"
chmod 2770 "$APP/src"
[ -f "$APP/src/main.js" ] || echo "// app source" > "$APP/src/main.js"
[ -f "$APP/src/server.js" ] || cp -n "$(dirname "$0")/../app/server.js" "$APP/src/server.js" 2>/dev/null || true
chown root:abdur_devs "$APP/src"/* 2>/dev/null || true
chmod 0660 "$APP/src"/*.js 2>/dev/null || true

# --- config: abdur_ops read+write, abdur_devs read-only (via ACL). -----------------------
chown -R root:abdur_ops "$APP/config"
chmod 2770 "$APP/config"
[ -f "$APP/config/app.conf" ] || printf 'PORT=3100\nLOG_LEVEL=info\n' > "$APP/config/app.conf"
chown root:abdur_ops "$APP/config"/*
chmod 0660 "$APP/config"/*

# --- secrets: abdur_ops read. Directory listable by abdur_auditor, contents not. ---------
chown -R root:abdur_ops "$APP/secrets"
chmod 0750 "$APP/secrets"
[ -f "$APP/secrets/db-password.txt" ] || echo 'hunter2-not-the-real-one' > "$APP/secrets/db-password.txt"
chown root:abdur_ops "$APP/secrets/db-password.txt"
chmod 0640 "$APP/secrets/db-password.txt"

# --- logs: the service writes, abdur_devs read. ------------------------------------
chown -R abdur_myappuser:abdur_devs "$APP/logs"
chmod 2770 "$APP/logs"
[ -f "$APP/logs/app.log" ] || echo "$(date -Is) app started" > "$APP/logs/app.log"
chown abdur_myappuser:abdur_devs "$APP/logs/app.log"
chmod 0660 "$APP/logs/app.log"

# --- backups: abdur_carol owns the directory (the brief requires it). --------------
chown abdur_carol:abdur_ops "$APP/backups"
# 3770 = setgid + sticky. Sticky stops abdur_ops members deleting each other's files,
# but NOT abdur_carol -- she owns the directory, which exempts her. See task 3.
chmod 3770 "$APP/backups"
for f in "${BACKUP_FILES[@]}"; do
  if [ ! -f "$APP/backups/$f" ]; then
    chattr -i "$APP/backups/$f" 2>/dev/null || true
    echo "dummy backup $f taken $(date -Is)" > "$APP/backups/$f"
  fi
  chattr -i "$APP/backups/$f"
  chown root:abdur_ops "$APP/backups/$f"
  chmod 0640 "$APP/backups/$f"
done

echo "== ACLs =="
# abdur_dan (abdur_auditor) gets read on everything EXCEPT the secrets file.
# rX = read, plus execute only where it is already a directory.
setfacl -R  -m g:abdur_auditor:rX "$APP/src" "$APP/config" "$APP/logs" "$APP/backups"
setfacl -R -d -m g:abdur_auditor:rX "$APP/src" "$APP/config" "$APP/logs" "$APP/backups"

# The service account can read its own source and config, but nothing else. It
# is deliberately NOT a member of abdur_devs -- membership would let a compromised
# app process write to the source tree.
setfacl -R  -m u:abdur_myappuser:rX "$APP/src" "$APP/config"
setfacl -R -d -m u:abdur_myappuser:rX "$APP/src" "$APP/config"

# abdur_devs get read-only on config so they can see what the app is configured with.
setfacl -R  -m g:abdur_devs:rX "$APP/config"
setfacl -R -d -m g:abdur_devs:rX "$APP/config"

# THE abdur_dan PROBLEM (task 2): the ACL goes on the DIRECTORY ONLY -- note there is
# no -R here. r+x on the directory lets abdur_dan read the filenames and stat them
# (that is what `ls -l` needs). The file keeps plain 0640 root:abdur_ops with no ACL
# at all, so `cat` is denied. No default ACL either: files created here later
# are unreadable by abdur_dan by default.
setfacl -m g:abdur_auditor:rx "$APP/secrets"
setfacl -b "$APP/secrets/db-password.txt" 2>/dev/null || true
chmod 0640 "$APP/secrets/db-password.txt"

echo "== immutability on backups (task 3) =="
# This, not the sticky bit, is what actually stops abdur_carol. Requires ext4/xfs.
for f in "${BACKUP_FILES[@]}"; do chattr +i "$APP/backups/$f"; done
lsattr "$APP/backups"

echo "== sudoers =="
install -m 0440 -o root -g root "$(dirname "$0")/sudoers-myapp" /etc/sudoers.d/abdur-myapp
visudo -cf /etc/sudoers.d/abdur-myapp

echo "== result =="
ls -la "$APP"
getfacl -p "$APP/secrets" 2>/dev/null | sed 's/^/  /'
echo "OK"
