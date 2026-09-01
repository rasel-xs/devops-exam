#!/usr/bin/env bash
# B3 task 31 -- load generator.
#
#   ./loadtest.sh [base_url] [duration_seconds]
#   ./loadtest.sh http://localhost:3000 300
#
# Produces, on purpose:
#   * at least 5 minutes of traffic across all endpoints and 5 tenants
#   * a 30-second BURST partway through (needed for the saturation panel)
#   * one deliberately heavy tenant (acme, ?limit=5000) so Panel H has a clear
#     worst tenant, and Panel G has the unbounded-limit rows to expose
set -u

BASE="${1:-http://localhost:3000}"
DURATION="${2:-300}"
BURST_AT=$((DURATION / 2))          # burst starts halfway through
BURST_FOR=30
TENANTS=(acme globex initech umbrella hooli)

echo "EXAM_TOKEN: ${EXAM_TOKEN:-NOT SET} | $(date)"
echo "target=$BASE duration=${DURATION}s burst at +${BURST_AT}s for ${BURST_FOR}s"
echo

req() { curl -s -o /dev/null -H "X-Tenant: $1" --max-time 30 "$BASE$2"; }

# ---------------------------------------------------------------- the burst ---
burst() {
  local end=$((SECONDS + BURST_FOR))
  echo ">>> $(date +%T) BURST START (20 extra concurrent workers)"
  while [ $SECONDS -lt "$end" ]; do
    for _ in $(seq 1 20); do
      req acme "/api/notes?limit=200" &
      req acme "/api/stats" &
    done
    wait
  done
  echo ">>> $(date +%T) BURST END"
}

# ------------------------------------------------------------- steady state ---
END=$((SECONDS + DURATION))
burst_started=0
n=0

while [ $SECONDS -lt $END ]; do
  T=${TENANTS[$RANDOM % ${#TENANTS[@]}]}

  # acme is the deliberately bad tenant: it asks for 5000 rows at a time, which
  # is Problem 4 (unbounded limit) made visible in db_rows_returned.
  if [ "$T" = "acme" ]; then
    req "$T" "/api/notes?limit=5000" &
  else
    req "$T" "/api/notes?limit=20" &
  fi

  req "$T" "/api/search?q=abc" &
  req "$T" "/api/stats" &
  req "$T" "/api/notes/1" &
  req "$T" "/healthz" &

  n=$((n + 5))

  if [ "$burst_started" -eq 0 ] && [ $SECONDS -ge "$BURST_AT" ]; then
    burst_started=1
    burst &
  fi

  sleep 0.2
done

wait
echo
echo "$(date +%T) done -- roughly $n requests issued over ${DURATION}s"
echo "check: curl -s $BASE/metrics | grep -E '^http_requests_total' | head"
