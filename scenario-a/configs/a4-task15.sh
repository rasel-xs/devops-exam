#!/usr/bin/env bash
# A4 task 15 -- the app that is alive but dead, and the watchdog that catches it.
set -u
UNIT=abdur-myapp
PORT=3100

hr() { printf '\n============ %s ============\n' "$*"; }
echo "EXAM_TOKEN: ${EXAM_TOKEN:-NOT SET}"
echo "date      : $(date)"

hr "1. BEFORE: the app is healthy"
echo "state    : $(systemctl is-active $UNIT)"
PID_BEFORE=$(systemctl show -p MainPID --value $UNIT)
echo "main pid : $PID_BEFORE"
printf 'healthz  : '; curl -s --max-time 3 "http://127.0.0.1:$PORT/healthz"

hr "2. Hit /hang -- the app answers, then stops answering forever"
echo -n "response from /hang: "
curl -s --max-time 3 "http://127.0.0.1:$PORT/hang"
sleep 1

hr "3. THE POINT OF THIS TASK"
echo "--- what systemd thinks ---"
echo "state    : $(systemctl is-active $UNIT)"
echo "main pid : $(systemctl show -p MainPID --value $UNIT)   (unchanged: $PID_BEFORE)"
systemctl status $UNIT --no-pager -n 0 | head -4
echo
echo "--- what a real request sees ---"
echo -n "curl --max-time 5 /healthz : "
if curl -s --max-time 5 "http://127.0.0.1:$PORT/healthz"; then
  echo "  ANSWERED (unexpected)"
else
  echo "TIMED OUT after 5s (curl exit $?)"
fi
echo
echo "--- and the socket is still open, which is why nothing looks wrong ---"
ss -lntp "sport = :$PORT"
echo
echo "The process is alive, the port is bound, the TCP handshake still completes"
echo "because the kernel accepts connections on the app's behalf. systemd sees"
echo "no exit, no signal, no failure -- so Restart=on-failure has nothing to"
echo "react to. Liveness has to be asked at the HTTP layer, not the process one."

hr "4. Waiting for the watchdog timer to notice"
systemctl list-timers abdur-myapp-watchdog.timer --no-pager || true
echo
HANG_AT=$(date +%s)
echo "hung at    : $(date +%T)"
for i in $(seq 1 24); do
  sleep 5
  NOW_PID=$(systemctl show -p MainPID --value $UNIT)
  if [ "$NOW_PID" != "$PID_BEFORE" ] && [ "$NOW_PID" != "0" ]; then
    RECOVERED=$(date +%s)
    echo "recovered  : $(date +%T)   (new pid $NOW_PID, was $PID_BEFORE)"
    echo "elapsed    : $((RECOVERED - HANG_AT)) seconds"
    break
  fi
  printf '  %s still hung (pid %s)\n' "$(date +%T)" "$NOW_PID"
done

hr "5. AFTER: is it serving again?"
printf 'healthz  : '; curl -s --max-time 3 "http://127.0.0.1:$PORT/healthz" || echo "STILL DOWN"
echo "state    : $(systemctl is-active $UNIT)"

hr "6. The timeline, with timestamps"
journalctl -u $UNIT -u abdur-myapp-watchdog.service -t abdur-myapp-watchdog \
  --since "3 min ago" --no-pager
hr "END"
