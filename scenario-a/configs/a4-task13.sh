#!/usr/bin/env bash
# A4 task 13 -- crash the app six times and watch what the unit does about it.
#
#   bash configs/a4-task13.sh          # with StartLimitBurst=5 -> gives up
#   bash configs/a4-task13.sh always   # with Restart=always     -> never gives up
set -u
UNIT=abdur-myapp
PORT=3100
MODE="${1:-limited}"

echo "EXAM_TOKEN: ${EXAM_TOKEN:-NOT SET}"
echo "date      : $(date)"
echo "mode      : $MODE"
echo

echo "============ BEFORE ============"
systemctl show "$UNIT" -p NRestarts -p Restart -p StartLimitBurst -p StartLimitIntervalUSec
echo "state    : $(systemctl is-active "$UNIT")"
echo "main pid : $(systemctl show -p MainPID --value "$UNIT")"

# The start-limit window is a rolling 60s. Any restarts from earlier testing
# would otherwise count against the burst and the service would hit the limit
# after fewer than six crashes, which would look like the wrong number.
echo
echo "resetting the counter so the six crashes start from a clean window..."
systemctl reset-failed "$UNIT" 2>/dev/null
systemctl restart "$UNIT"
sleep 2

echo
echo "============ CRASHING IT SIX TIMES ============"
for i in $(seq 1 6); do
  printf '%s crash %d -> ' "$(date +%T)" "$i"
  curl -s --max-time 2 "http://127.0.0.1:$PORT/crash" || printf '(app was already down)'
  printf '  | pid now: %s  state: %s\n' \
    "$(systemctl show -p MainPID --value "$UNIT")" \
    "$(systemctl is-active "$UNIT")"
  sleep 2
done

echo
echo "============ AFTER ============"
sleep 3
systemctl status "$UNIT" --no-pager -n 0 || true
echo
echo "NRestarts : $(systemctl show -p NRestarts --value "$UNIT")"
echo "state     : $(systemctl is-active "$UNIT")"
echo "result    : $(systemctl show -p Result --value "$UNIT")"
echo
echo "--- is the port still served? ---"
curl -s --max-time 2 "http://127.0.0.1:$PORT/healthz" \
  && echo "  still answering" \
  || echo "  nothing on port $PORT -- the service is down for good"

echo
echo "============ JOURNAL ============"
journalctl -u "$UNIT" -n 40 --no-pager
