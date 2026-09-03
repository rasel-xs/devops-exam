#!/usr/bin/env bash
# B3 task 31 -- load generator.
#
#   bash app/loadtest.sh [base_url] [duration_seconds]
#   bash app/loadtest.sh http://127.0.0.1:3120 300
#
# Produces, on purpose:
#   * 5 minutes of traffic across every endpoint and all 5 tenants
#   * a 30-second BURST partway through, for the saturation panel
#   * acme as the deliberately heavy tenant (?limit=5000), so panel G has
#     unbounded-limit rows to expose and panel H has a clear worst tenant
#
# Two corrections to the first version, both found by reading task 30's
# evidence rather than by the script failing:
#
#   1. It requested /api/notes/1 for EVERY tenant. Note ids are not shared:
#      acme is seeded first and owns 1..30000, so every other tenant got a 404,
#      the tags query never ran, and the N+1 never happened. 40 of 70 requests
#      in that run were 404s. Ids are now looked up per tenant.
#   2. It searched for `abc`. Seeded bodies are concatenated md5, so a 3-hex
#      fragment matches thousands of rows, `LIMIT 50` fills almost immediately
#      and Postgres STOPS SCANNING -- which hides the sequential scan that
#      deliberate problem 2 is about. A random 5-hex fragment matches almost
#      nothing, so the scan runs to the end. The slow case is the honest case.
set -u

BASE="${1:-http://127.0.0.1:3120}"
DURATION="${2:-300}"
BURST_AT=$((DURATION / 2))
BURST_FOR=30
TENANTS=(acme globex initech umbrella hooli)
COMPOSE="docker compose -f $(dirname "$0")/../docker/docker-compose.yml"

echo "EXAM_TOKEN: ${EXAM_TOKEN:-NOT SET} | $(date)"
echo "target=$BASE duration=${DURATION}s burst at +${BURST_AT}s for ${BURST_FOR}s"

# ------------------------------------------------- per-tenant note ids ---
# Ids are SAMPLED, not derived from min/max.
#
# The first version used `SELECT min(id), max(id) ... GROUP BY slug` and printed
# `acme 1..50003`. acme really owns 1..30000; ids 30001..50000 belong to the
# other four tenants, and 50001..50003 are the three marker notes B2 task 27
# inserted as acme. min/max only describes a RANGE if the ids are contiguous,
# and task 27 destroyed that. Picking uniformly in 1..50003 sent ~40% of acme's
# /api/notes/:id requests at other tenants' rows -- 404s again, the exact bug
# this section exists to prevent.
#
# Sampling real ids cannot be wrong regardless of how the ids are laid out.
declare -A IDS
SAMPLE_SQL="SELECT t.slug, n.id FROM tenants t
              JOIN LATERAL (SELECT id FROM notes WHERE tenant_id = t.id
                             ORDER BY random() LIMIT 100) n ON true"
if SAMPLE=$($COMPOSE exec -T postgres psql -U notes -d notes -tAF' ' -c "$SAMPLE_SQL" 2>/dev/null) \
   && [ -n "$SAMPLE" ]; then
  while read -r slug id; do
    [ -n "${slug:-}" ] || continue
    IDS[$slug]="${IDS[$slug]:-} $id"
  done <<< "$SAMPLE"
  echo "sampled 100 real note ids per tenant from postgres:"
else
  echo "WARNING: could not reach postgres. Falling back to id 1 for every"
  echo "tenant, which means every non-acme request will 404. Fix this before"
  echo "trusting any number from this run."
  for t in "${TENANTS[@]}"; do IDS[$t]="1"; done
fi
for t in "${TENANTS[@]}"; do
  # shellcheck disable=SC2086
  set -- ${IDS[$t]}
  printf '  %-9s %d ids, e.g. %s %s %s\n' "$t" "$#" "${1:-?}" "${2:-?}" "${3:-?}"
done
echo

rand_id() {
  # shellcheck disable=SC2086
  set -- ${IDS[$1]}
  eval echo "\${$(( RANDOM % $# + 1 ))}"
}
# 5 hex chars: rare enough that LIMIT 50 is never reached, so the scan is full.
rand_hex() { printf '%05x' $(( RANDOM * 32 + RANDOM % 32 )); }

req() { curl -s -o /dev/null -H "X-Tenant: $1" --max-time 30 "$BASE$2" </dev/null; }

# ---------------------------------------------------------------- burst ---
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

# ----------------------------------------------------------- steady state ---
END=$((SECONDS + DURATION))
burst_started=0
n=0

while [ $SECONDS -lt $END ]; do
  T=${TENANTS[$RANDOM % ${#TENANTS[@]}]}

  # acme is the deliberately bad tenant: ONE IN FIVE of its list requests asks
  # for 5000 rows -- problem 4 (unbounded limit), and with the N+1 that is 5001
  # sequential queries in a single request.
  #
  # Why one in five and not every time. The tag loop is `for ... await`, i.e.
  # strictly sequential, so a limit=5000 request takes seconds and holds a pool
  # connection for all of it. Sending one every second would keep the app
  # permanently saturated for the whole five minutes: everything times out, the
  # burst becomes invisible, and every panel shows the same flat wall. As a
  # TAIL it is far more legible -- a clear 5000 tail in db_rows_returned, an
  # isolated point in the 1000+ bucket of db_queries_per_request, a visibly
  # worse p95 for acme in panel H -- and the burst still stands out. Pathology
  # shows up in production as a tail, not as the whole distribution.
  if [ "$T" = "acme" ] && [ $((RANDOM % 5)) -eq 0 ]; then
    req "$T" "/api/notes?limit=5000" &
  elif [ "$T" = "acme" ]; then
    req "$T" "/api/notes?limit=20" &
  else
    req "$T" "/api/notes?limit=20" &
  fi

  req "$T" "/api/search?q=$(rand_hex)" &
  req "$T" "/api/stats" &
  req "$T" "/api/notes/$(rand_id "$T")" &
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

# ------------------------------------------------------------- summary ---
# Printed from the app's own metrics, so the run can be checked without opening
# Grafana. A load test with no assertion is just noise.
#
# Parsed by docker/metricfmt.py rather than grep/sed: label ORDER is not stable
# (http_requests_total puts `status` after `route`, `_bucket` puts `le` first),
# and a pattern that assumes an order prints nothing, which is indistinguishable
# from a metric that does not exist. I made that mistake three times in task 29.
echo
curl -s "$BASE/metrics" </dev/null | python3 "$(dirname "$0")/../docker/metricfmt.py"
