#!/usr/bin/env bash
# A1 — team access on the inherited server.
# Idempotent: safe to re-run. Run as root on the VPS.
#
#   sudo bash setup-users.sh
#
# Design notes (the reasoning is in ../ANSWERS.md):
#   * "others" gets nothing anywhere under /srv/app. Every cross-team read is an
#     explicit ACL entry, so `getfacl` documents the access model.
#   * dan reads via the `auditor` group ACL, never via o+r.
#   * setgid on every directory so new files inherit the owning group.
#   * the secrets directory gets an ACL; the secrets FILE deliberately does not.

set -euo pipefail

APP=/srv/app
BACKUP_FILES=(backup1.tar backup2.tar backup3.tar)

need() { command -v "$1" >/dev/null || { echo "missing: $1"; exit 1; }; }
need setfacl
need chattr

echo "== groups =="
for g in devs ops auditor; do
  getent group "$g" >/dev/null || groupadd "$g"
  echo "  group $g ok"
done

echo "== users =="
# alice/bob: devs. carol: primary ops, secondary devs (the brief says she can do
# "everything devs can do", so she is genuinely a member of devs). dan: auditor.
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
add_user alice devs
add_user bob   devs
add_user carol ops   devs
add_user dan   auditor

# The service account. Cannot log in, owns nothing it does not need.
id -u myappuser >/dev/null 2>&1 || \
  useradd --system --no-create-home --shell /usr/sbin/nologin myappuser
echo "  $(id myappuser)"

echo "== directories =="
mkdir -p "$APP"/{src,config,secrets,logs,backups}

# /srv/app itself is only a doorway: everyone may traverse it, nobody may write.
chown root:root "$APP"
chmod 0755 "$APP"

# --- src: devs (and carol, who is in devs) read+write. -----------------------
chown -R root:devs "$APP/src"
chmod 2770 "$APP/src"
[ -f "$APP/src/main.js" ] || echo "// app source" > "$APP/src/main.js"
[ -f "$APP/src/server.js" ] || cp -n "$(dirname "$0")/../app/server.js" "$APP/src/server.js" 2>/dev/null || true
chown root:devs "$APP/src"/* 2>/dev/null || true
chmod 0660 "$APP/src"/*.js 2>/dev/null || true

# --- config: ops read+write, devs read-only (via ACL). -----------------------
chown -R root:ops "$APP/config"
chmod 2770 "$APP/config"
[ -f "$APP/config/app.conf" ] || printf 'PORT=3000\nLOG_LEVEL=info\n' > "$APP/config/app.conf"
chown root:ops "$APP/config"/*
chmod 0660 "$APP/config"/*

# --- secrets: ops read. Directory listable by auditor, contents not. ---------
chown -R root:ops "$APP/secrets"
chmod 0750 "$APP/secrets"
[ -f "$APP/secrets/db-password.txt" ] || echo 'hunter2-not-the-real-one' > "$APP/secrets/db-password.txt"
chown root:ops "$APP/secrets/db-password.txt"
chmod 0640 "$APP/secrets/db-password.txt"

# --- logs: the service writes, devs read. ------------------------------------
chown -R myappuser:devs "$APP/logs"
chmod 2770 "$APP/logs"
[ -f "$APP/logs/app.log" ] || echo "$(date -Is) app started" > "$APP/logs/app.log"
chown myappuser:devs "$APP/logs/app.log"
chmod 0660 "$APP/logs/app.log"

# --- backups: carol owns the directory (the brief requires it). --------------
chown carol:ops "$APP/backups"
# 3770 = setgid + sticky. Sticky stops ops members deleting each other's files,
# but NOT carol -- she owns the directory, which exempts her. See task 3.
chmod 3770 "$APP/backups"
for f in "${BACKUP_FILES[@]}"; do
  if [ ! -f "$APP/backups/$f" ]; then
    chattr -i "$APP/backups/$f" 2>/dev/null || true
    echo "dummy backup $f taken $(date -Is)" > "$APP/backups/$f"
  fi
  chattr -i "$APP/backups/$f"
  chown root:ops "$APP/backups/$f"
  chmod 0640 "$APP/backups/$f"
done

echo "== ACLs =="
# dan (auditor) gets read on everything EXCEPT the secrets file.
# rX = read, plus execute only where it is already a directory.
setfacl -R  -m g:auditor:rX "$APP/src" "$APP/config" "$APP/logs" "$APP/backups"
setfacl -R -d -m g:auditor:rX "$APP/src" "$APP/config" "$APP/logs" "$APP/backups"

# The service account can read its own source and config, but nothing else. It
# is deliberately NOT a member of devs -- membership would let a compromised
# app process write to the source tree.
setfacl -R  -m u:myappuser:rX "$APP/src" "$APP/config"
setfacl -R -d -m u:myappuser:rX "$APP/src" "$APP/config"

# devs get read-only on config so they can see what the app is configured with.
setfacl -R  -m g:devs:rX "$APP/config"
setfacl -R -d -m g:devs:rX "$APP/config"

# THE dan PROBLEM (task 2): the ACL goes on the DIRECTORY ONLY -- note there is
# no -R here. r+x on the directory lets dan read the filenames and stat them
# (that is what `ls -l` needs). The file keeps plain 0640 root:ops with no ACL
# at all, so `cat` is denied. No default ACL either: files created here later
# are unreadable by dan by default.
setfacl -m g:auditor:rx "$APP/secrets"
setfacl -b "$APP/secrets/db-password.txt" 2>/dev/null || true
chmod 0640 "$APP/secrets/db-password.txt"

echo "== immutability on backups (task 3) =="
# This, not the sticky bit, is what actually stops carol. Requires ext4/xfs.
for f in "${BACKUP_FILES[@]}"; do chattr +i "$APP/backups/$f"; done
lsattr "$APP/backups"

echo "== sudoers =="
install -m 0440 -o root -g root "$(dirname "$0")/sudoers-myapp" /etc/sudoers.d/myapp
visudo -cf /etc/sudoers.d/myapp

echo "== result =="
ls -la "$APP"
getfacl -p "$APP/secrets" 2>/dev/null | sed 's/^/  /'
echo "OK"
