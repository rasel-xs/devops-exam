#!/usr/bin/env bash
# B3 task 30 -- Prometheus scrapes the app. Proven from Prometheus's own API,
# not from "the UI looked green".
set -u
C="docker compose -f docker/docker-compose.yml"
API=http://127.0.0.1:3120
PROM=http://127.0.0.1:9190
step()   { echo; echo "--- $* ---"; }
banner() { echo; echo "############ $* ############"; echo "EXAM_TOKEN: ${EXAM_TOKEN:-NOT SET} | $(date)"; }

# Format Prometheus JSON. The formatter lives in docker/promfmt.py rather than
# in a `python3 -c` one-liner: the shell wrapper here is single-quoted, so every
# double quote in the Python needed a backslash, and `\"` inside an f-string
# expression is a SyntaxError. Eight of my nine formatters died that way while
# the data behind them was perfectly fine.
pq() {
  curl -sG "$PROM/api/v1/query" --data-urlencode "query=$1" </dev/null \
    | python3 docker/promfmt.py query
}

banner "TASK 30  Prometheus"

step "bring the whole stack up (app, postgres, prometheus, grafana)"
$C up -d
for i in $(seq 1 60); do
  curl -s "$PROM/-/ready" </dev/null | grep -q . && break
  sleep 1
done
echo "  prometheus says: $(curl -s $PROM/-/ready </dev/null)"
echo "  version: $(curl -s $PROM/api/v1/status/buildinfo </dev/null | sed -n 's/.*"version":"\([^"]*\)".*/\1/p')"

step "generate some traffic so there is something to scrape"
for i in $(seq 1 20); do
  curl -s -o /dev/null -H 'X-Tenant: acme' "$API/api/notes?limit=20" </dev/null
  curl -s -o /dev/null -H 'X-Tenant: globex' "$API/api/notes/$i" </dev/null
done
echo "  waiting 15s for at least 3 scrapes at 5s interval..."
sleep 15

step "TARGETS -- health, the resolved address, and how stale the data is"
curl -s "$PROM/api/v1/targets" </dev/null | python3 docker/promfmt.py targets

step "the up metric -- 1 means the last scrape succeeded"
pq 'up'

step "external_labels do NOT appear on local series -- I had this wrong"
# I expected env="exam" on every series. It is not there, and that is correct:
# external_labels are attached only when data LEAVES this Prometheus --
# remote_write, federation, and alerts sent to Alertmanager. They are never
# written into the local TSDB. The config below proves the label is loaded.
# It matters in task 33: the alert notification will carry env=exam even though
# no graph here does.
pq 'up{env="exam"}'
echo "  ^ empty is the CORRECT result; compare the loaded config further down"

step "did the app's own metrics arrive?"
pq 'sum(http_requests_total)'
pq 'sum by (route) (http_requests_total)'

step "a rate() -- this is the query type Prometheus exists for"
pq 'sum(rate(http_requests_total[1m]))'

step "p95 latency from the histogram, per route"
pq 'histogram_quantile(0.95, sum by (route, le) (rate(http_request_duration_seconds_bucket[1m])))'

step "mean DB queries per request, per route -- the N+1 in PromQL"
pq 'rate(db_queries_per_request_sum[1m]) / rate(db_queries_per_request_count[1m])'

step "how many series is this Prometheus holding?"
curl -s "$PROM/api/v1/status/tsdb" </dev/null | tr ',' '\n' | grep -i 'numSeries\|numLabelPairs\|chunkCount' | sed 's/^/  /'

step "config Prometheus actually loaded (not the file on disk)"
curl -s "$PROM/api/v1/status/config" </dev/null \
  | python3 -c "import json,sys; print(json.load(sys.stdin)['data']['yaml'])" \
  | grep -E 'scrape_interval|job_name|targets|env:|rule_files|- /etc|- app:|- localhost' | sed 's/^/  /'

step "PROOF that app:3000 resolved -- up{job=\"notes-api\"} is 1"
# busybox `nslookup` inside the prometheus image reports "Can't find app: No
# answer" even while scraping works, so it proves nothing either way (same trap
# as B2 task 28b: never let a missing or quirky applet stand in for evidence).
# A successful scrape of app:3000 IS the DNS proof.
pq 'up{job="notes-api"}'
echo "  target URL Prometheus is actually hitting:"
curl -s "$PROM/api/v1/targets" </dev/null | tr ',' '\n' | grep scrapeUrl | sed 's/^/    /'

echo; echo "############ task 30 complete ############"
