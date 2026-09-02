#!/usr/bin/env bash
# A4 task 14 -- the five journalctl queries the brief asks for.
set -u
UNIT=abdur-myapp

hr() { printf '\n============ %s ============\n' "$*"; }

echo "EXAM_TOKEN: ${EXAM_TOKEN:-NOT SET}"
echo "date      : $(date)"

hr "1. All logs from the last 10 minutes"
echo '$ journalctl -u abdur-myapp --since "10 min ago" --no-pager'
journalctl -u "$UNIT" --since "10 min ago" --no-pager | tail -20
echo "  ... (tail -20 shown; the query itself is unbounded)"

hr "2. Errors and worse"
echo '$ journalctl -u abdur-myapp -p err --no-pager'
# -p takes a MAXIMUM priority: err(3) also returns crit(2), alert(1), emerg(0).
# It is a threshold, not an exact match. `-p err..err` would be exact.
journalctl -u "$UNIT" -p err --no-pager | tail -15
echo
echo "  proof that -p is a threshold and not an exact level:"
echo "  err and worse : $(journalctl -u "$UNIT" -p err --no-pager | wc -l) lines"
echo "  warning and worse: $(journalctl -u "$UNIT" -p warning --no-pager | wc -l) lines"
echo "  info and worse   : $(journalctl -u "$UNIT" -p info --no-pager | wc -l) lines"

hr "3a. Current boot only"
echo '$ journalctl -u abdur-myapp -b 0 --no-pager'
journalctl -u "$UNIT" -b 0 --no-pager | tail -8

hr "3b. Previous boot"
echo '$ journalctl --list-boots'
journalctl --list-boots --no-pager 2>&1 | tail -5
echo
echo '$ journalctl -u abdur-myapp -b -1 --no-pager'
journalctl -u "$UNIT" -b -1 --no-pager 2>&1 | tail -8
echo
echo "  If that says 'Specified boot ID not found', the journal is VOLATILE:"
echo "  /run/log/journal is tmpfs and is wiped at every boot, so there is no"
echo "  previous boot to read. Persisting it needs Storage=persistent in"
echo "  /etc/systemd/journald.conf plus /var/log/journal to exist."
echo "  Current storage:"
ls -d /var/log/journal 2>/dev/null && echo "    /var/log/journal exists -> persistent" \
  || echo "    /var/log/journal missing -> volatile (this boot only)"

hr "4. JSON output"
echo '$ journalctl -u abdur-myapp -n 2 -o json-pretty --no-pager'
journalctl -u "$UNIT" -n 2 -o json-pretty --no-pager
echo
echo "  -o json gives one object PER LINE instead, which is the form you pipe"
echo "  to jq or ship to a log collector:"
echo '$ journalctl -u abdur-myapp -n 3 -o json --no-pager | jq -r ".MESSAGE"'
journalctl -u "$UNIT" -n 3 -o json --no-pager | jq -r '.MESSAGE' 2>/dev/null \
  || journalctl -u "$UNIT" -n 3 -o json --no-pager | cut -c1-100

hr "5. Follow the logs live while the service restarts"
echo '$ journalctl -u abdur-myapp -f     (in one terminal)'
echo '$ systemctl restart abdur-myapp    (in another)'
echo
echo "Doing both here: -f runs in the background, capturing while we restart."
journalctl -u "$UNIT" -f --no-pager > /tmp/abdur-follow.log 2>&1 &
FOLLOW_PID=$!
sleep 2
echo ">>> $(date +%T) systemctl restart abdur-myapp"
systemctl restart "$UNIT"
sleep 4
kill "$FOLLOW_PID" 2>/dev/null
wait "$FOLLOW_PID" 2>/dev/null
echo
echo "--- what -f captured as it happened ---"
cat /tmp/abdur-follow.log
rm -f /tmp/abdur-follow.log

hr "BONUS: SyslogIdentifier lets you filter without -u"
echo '$ journalctl -t abdur-myapp -n 3 --no-pager'
journalctl -t "$UNIT" -n 3 --no-pager
echo
echo "  -u filters by UNIT (includes systemd's own messages about the unit)."
echo "  -t filters by SyslogIdentifier (only what the app itself wrote)."
hr "END"
