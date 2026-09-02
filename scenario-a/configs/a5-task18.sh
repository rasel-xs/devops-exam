#!/usr/bin/env bash
# A5 task 18 -- passive health checks and failover, measured.
#
#   bash configs/a5-task18.sh "3 fails / 10s"        # default 35s downtime
#   bash configs/a5-task18.sh "1 fail / 30s"  15       # 15s downtime
#
# Runs a continuous request loop, stops backend 3102, waits, starts it again,
# and reports what the CLIENT saw as well as what nginx recorded internally.
# Those are different numbers, and the difference is proxy_next_upstream.
set -u
LABEL="${1:-current settings}"
URL=http://127.0.0.1:8110/
BACKEND=abdur-myapp@3102
LOOPLOG=/tmp/abdur-failover.log
ERRLOG=/var/log/nginx/abdur-myapp.error.log
# How long to leave the backend stopped. This matters more than it looks:
# if the downtime is LONGER than fail_timeout, the ban has already expired by
# the time the backend returns and recovery looks instant either way. To see
# what fail_timeout actually costs, the backend has to come back while it is
# still banned -- hence the shorter downtime for the 30s run.
DOWN_FOR="${2:-35}"
SETTLE=45          # seconds to watch it come back

hr() { printf '\n============ %s ============\n' "$*"; }
echo "EXAM_TOKEN: ${EXAM_TOKEN:-NOT SET}"
echo "date      : $(date)"
echo "settings  : $LABEL"
grep -nE '^\s+server 127\.0\.0\.1' /etc/nginx/sites-available/abdur-myapp

: > "$LOOPLOG"
ERR_BEFORE=$(wc -l < "$ERRLOG" 2>/dev/null || echo 0)

hr "starting the request loop (2 req/s)"
(
  while true; do
    resp=$(curl -s --max-time 2 "$URL" | grep -o 'port [0-9]*' || true)
    printf '%s %s\n' "$(date +%T.%3N)" "${resp:-FAILED}"
    sleep 0.5
  done
) > "$LOOPLOG" 2>&1 &
LOOP_PID=$!

sleep 10
echo "baseline (10s of normal traffic):"
awk '{print $2, $3}' "$LOOPLOG" | sort | uniq -c

hr "stopping backend 3102"
STOP_AT=$(date +%T.%3N)
systemctl stop "$BACKEND"
echo "stopped at : $STOP_AT"
sleep "$DOWN_FOR"

hr "starting backend 3102 again"
START_AT=$(date +%T.%3N)
systemctl start "$BACKEND"
echo "started at : $START_AT"
sleep "$SETTLE"

kill "$LOOP_PID" 2>/dev/null; wait "$LOOP_PID" 2>/dev/null

hr "WHAT THE CLIENT SAW"
awk '{print $2, $3}' "$LOOPLOG" | sort | uniq -c
echo
echo "client-visible failures : $(grep -c FAILED "$LOOPLOG")"
echo "total requests          : $(wc -l < "$LOOPLOG")"

hr "TIMELINE around the stop"
echo "(stopped at $STOP_AT)"
awk -v t="$STOP_AT" '$1 >= t' "$LOOPLOG" | head -20

hr "TIMELINE around the restart"
echo "(started at $START_AT)"
awk -v t="$START_AT" '$1 >= t' "$LOOPLOG" | head -30

hr "FIRST REQUEST BACK ON 3102 AFTER THE RESTART"
awk -v t="$START_AT" '$1 >= t && /3102/ {print; exit}' "$LOOPLOG" \
  || echo "  3102 never came back within the observation window"

hr "WHAT NGINX RECORDED INTERNALLY"
echo "These are the failures the client never saw, because"
echo "proxy_next_upstream retried them on the healthy backend."
tail -n +"$((ERR_BEFORE + 1))" "$ERRLOG" 2>/dev/null \
  | grep -c 'upstream' | xargs echo "upstream error lines :"
echo
tail -n +"$((ERR_BEFORE + 1))" "$ERRLOG" 2>/dev/null | grep 'upstream' | head -6

hr "END"
echo "full loop log kept at $LOOPLOG"
