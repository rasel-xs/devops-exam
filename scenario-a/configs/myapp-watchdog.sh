#!/usr/bin/env bash
# /usr/local/bin/myapp-watchdog.sh
#
# A4 task 15. The app can be alive-but-dead: it accepts TCP connections and
# never answers. systemd sees a running process and is perfectly happy, so
# Restart=on-failure never fires. This asks the app a question instead of
# asking the kernel whether the process exists.
set -u

URL="${WATCHDOG_URL:-http://127.0.0.1:3000/healthz}"
UNIT="${WATCHDOG_UNIT:-myapp}"
TIMEOUT="${WATCHDOG_TIMEOUT:-5}"

# -f makes curl exit non-zero on a 4xx/5xx as well as on a transport error, so
# an app that answers "500 everything is broken" also counts as unhealthy.
# --max-time is the whole point: /hang never replies, so without it curl waits
# for ever and the watchdog hangs alongside the thing it is watching.
if curl -sf --max-time "$TIMEOUT" "$URL" >/dev/null 2>&1; then
  echo "healthy: $URL responded within ${TIMEOUT}s"
  exit 0
fi

# logger writes to the journal, so the restart decision and the restart itself
# land in the same timeline you read with journalctl.
logger -t myapp-watchdog "UNHEALTHY: $URL did not answer within ${TIMEOUT}s -- restarting $UNIT"
echo "unhealthy: $URL did not answer within ${TIMEOUT}s -- restarting $UNIT"
systemctl restart "$UNIT"
rc=$?
logger -t myapp-watchdog "restart of $UNIT returned $rc"
exit "$rc"
