#!/usr/bin/env bash
# B2 task 26 -- prove that `depends_on:` alone is not enough.
#
# The original plan was "the app will crash with ECONNREFUSED". It does not,
# and the reason is worth more marks than the crash would have been:
#
#   * node-postgres `new Pool()` is LAZY -- it opens no socket until the first
#     query, so a missing database costs nothing at startup;
#   * `app.listen()` never touches the database;
#   * our /healthz is a LIVENESS probe and deliberately does not touch the
#     database either (B1 task 21c).
#
# So the container reports `Up (healthy)` while being completely unable to
# serve a single row. That is worse than a crash: a crash restarts and alerts,
# a lying healthcheck gets traffic routed to it.
#
# This script measures the window. /readyz DOES query the database, so it is
# the honest signal. We poll both probes every 0.5s from t=0 on a FRESH volume.

BROKEN=docker/docker-compose.broken-depends.yml
FIXED=docker/docker-compose.yml
URL=http://127.0.0.1:3120

section() { printf '\n\n========== %s ==========\n' "$*"; }

# Poll /healthz and /readyz every 0.5s until /readyz answers 200 (or we give
# up). Prints one line per tick so the window is visible, not just summarised.
poll() {
  local label=$1 t0 now el hc rc body first_healthy="" first_ready=""
  t0=$(date +%s%N)
  for _ in $(seq 1 80); do          # 80 x 0.5s = 40s ceiling
    now=$(date +%s%N)
    el=$(awk -v a="$t0" -v b="$now" 'BEGIN { printf "%6.1f", (b-a)/1000000000 }')
    hc=$(curl -s -o /dev/null -w '%{http_code}' --max-time 2 "$URL/healthz" </dev/null 2>/dev/null)
    rc=$(curl -s -o /dev/null -w '%{http_code}' --max-time 2 "$URL/readyz"  </dev/null 2>/dev/null)
    printf '  t=%ss  /healthz=%-3s  /readyz=%-3s\n' "$el" "${hc:-000}" "${rc:-000}"
    [ -z "$first_healthy" ] && [ "$hc" = "200" ] && first_healthy=$el
    if [ "$rc" = "200" ]; then first_ready=$el; break; fi
    sleep 0.5
  done
  # The failing body carries the real error -- worth showing once.
  body=$(curl -s --max-time 2 "$URL/readyz" </dev/null 2>/dev/null)
  printf '\n  %s: first HEALTHY at t=%ss, first READY at t=%ss\n' \
         "$label" "${first_healthy:-never}" "${first_ready:-never}"
  awk -v h="${first_healthy:-0}" -v r="${first_ready:-0}" \
      'BEGIN { printf "  >>> lying-healthy window = %.1f seconds\n", r - h }'
  printf '  last /readyz body: %s\n' "${body:0:200}"
}

section "TASK 26a -- depends_on only, FRESH volume"
docker compose -f "$BROKEN" down -v >/dev/null 2>&1
docker compose -f "$FIXED"  down    >/dev/null 2>&1   # free host port 3120
echo "--- up -d (nothing waits for anything) ---"
docker compose -f "$BROKEN" up -d
echo
echo "--- polling from t=0 ---"
poll "BROKEN"

section "TASK 26b -- who was ready when? (container clocks, not mine)"
echo "--- app: first log line ---"
docker compose -f "$BROKEN" logs --timestamps app 2>&1 | head -5
echo
echo "--- app: connection errors while postgres was still initialising ---"
docker compose -f "$BROKEN" logs --timestamps app 2>&1 \
  | grep -iE 'econnrefused|not ready|error' | head -10
echo "  (none above = the app never even tried; that is the point)"
echo
echo "--- postgres: initdb -> ready ---"
docker compose -f "$BROKEN" logs --timestamps postgres 2>&1 \
  | grep -iE 'initdb|ready to accept|database system is ready|shutting down' | head -10
echo
echo "--- what docker thought of the app the whole time ---"
docker compose -f "$BROKEN" ps -a
docker compose -f "$BROKEN" down -v >/dev/null 2>&1

section "TASK 26c -- condition: service_healthy, FRESH volume"
docker compose -f "$FIXED" down -v >/dev/null 2>&1
echo "--- up -d postgres app  (app is HELD until pg_isready passes) ---"
docker compose -f "$FIXED" up -d postgres app
echo
echo "--- polling from t=0 ---"
poll "FIXED"
echo
echo "--- postgres healthcheck transitions ---"
docker inspect --format '{{range .State.Health.Log}}{{.Start}} exit={{.ExitCode}} {{println .Output}}{{end}}' \
  "$(docker compose -f "$FIXED" ps -q postgres)" 2>/dev/null | head -12
echo
docker compose -f "$FIXED" ps

section "DONE"
echo "Compare the two 'lying-healthy window' numbers above."
