#!/usr/bin/env bash
# B3 task 29 -- prove the six metrics exist, are correctly typed, and that the
# route label is a PATTERN. The last one is the part that is easy to get wrong
# and impossible to fix later: once high-cardinality series are written, they
# are in the TSDB.
set -u
C="docker compose -f docker/docker-compose.yml"
API=http://127.0.0.1:3120
step()   { echo; echo "--- $* ---"; }
banner() { echo; echo "############ $* ############"; echo "EXAM_TOKEN: ${EXAM_TOKEN:-NOT SET} | $(date)"; }

banner "TASK 29  application metrics"

$C up -d postgres app >/dev/null 2>&1
for i in $(seq 1 60); do
  [ "$(curl -s -o /dev/null -w '%{http_code}' --max-time 2 "$API/readyz" </dev/null)" = "200" ] && break
  sleep 1
done
echo "  app ready"

step "generate traffic across every route, with MANY DIFFERENT note ids"
# 30 different ids on purpose: if the route label were the path, this alone
# would create 30 separate series and the check below would catch it.
for i in $(seq 1 30); do
  curl -s -o /dev/null -H 'X-Tenant: acme' "$API/api/notes/$i" </dev/null
done
for t in acme globex initech; do
  curl -s -o /dev/null -H "X-Tenant: $t" "$API/api/notes?limit=20"    </dev/null
  curl -s -o /dev/null -H "X-Tenant: $t" "$API/api/search?q=alpha"    </dev/null
  curl -s -o /dev/null -H "X-Tenant: $t" "$API/api/stats"             </dev/null
done
curl -s -o /dev/null "$API/healthz" </dev/null
curl -s -o /dev/null "$API/api/nonexistent-probe-url" </dev/null   # should become 'unmatched'
echo "  done"

step "all six metrics present, with their TYPE and HELP"
for m in http_requests_total http_request_duration_seconds db_query_duration_seconds \
         db_queries_per_request db_rows_returned http_requests_in_flight; do
  line=$(curl -s "$API/metrics" </dev/null | grep -m1 "^# TYPE $m ")
  printf '  %-32s %s\n' "$m" "${line:-*** MISSING ***}"
done

step "every distinct value of the route label"
curl -s "$API/metrics" </dev/null \
  | grep -o 'route="[^"]*"' | sort -u | sed 's/^/  /'

step "CARDINALITY CHECK -- a route label containing a bare number is a bug"
BAD=$(curl -s "$API/metrics" </dev/null | grep -o 'route="[^"]*"' | sort -u | grep -E 'route="[^"]*/[0-9]+' || true)
if [ -n "$BAD" ]; then
  echo "  FAIL -- these are paths, not patterns:"; echo "$BAD" | sed 's/^/    /'
else
  echo "  PASS -- 30 different note ids produced ONE series, not 30"
fi

step "total number of series exposed (the number that has to stay small)"
curl -s "$API/metrics" </dev/null | grep -vc '^#' | sed 's/^/  /'

step "THE N+1, visible in db_queries_per_request"
# NOTE on grepping the exposition format: DO NOT assume a label order.
# prom-client emits `_sum`/`_count` as {app="...",route="..."} but `_bucket`
# as {le="...",app="...",route="..."} -- `le` FIRST. I got this wrong twice:
# first by anchoring on `{route=`, then by matching `route="/api/notes",`
# with a trailing comma when route is the LAST label and is followed by `}`.
# Both printed nothing, which looks exactly like a missing metric. Anchor on
# the closing brace instead.
echo "  cumulative bucket counts for GET /api/notes (le = 'less than or equal'):"
curl -s "$API/metrics" </dev/null \
  | grep 'db_queries_per_request_bucket' | grep 'route="/api/notes"}' | sed 's/^/    /'
echo
echo "  the same histogram for a route with no N+1:"
curl -s "$API/metrics" </dev/null \
  | grep 'db_queries_per_request_bucket' | grep 'route="/api/notes/:id"}' | sed 's/^/    /'

step "sum/count let us read the MEAN queries per request per route"
curl -s "$API/metrics" </dev/null \
  | grep -E '^db_queries_per_request_(sum|count)' | sed 's/^/  /'

step "db_rows_returned -- the unbounded-limit detector, unprovoked so far"
curl -s "$API/metrics" </dev/null | grep -E '^db_rows_returned_(sum|count)' | sed 's/^/  /'

step "in-flight gauge is a GAUGE (it must be able to go down)"
curl -s "$API/metrics" </dev/null | grep -E '^(# TYPE )?http_requests_in_flight' | sed 's/^/  /'

step "free process metrics -- process_start_time_seconds catches crash-loops"
curl -s "$API/metrics" </dev/null | grep -E '^process_start_time_seconds|^nodejs_version_info' | sed 's/^/  /'

echo; echo "############ task 29 complete ############"
