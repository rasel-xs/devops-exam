#!/usr/bin/env bash
# B3 task 33 -- the alert. Not "here is a YAML file": the rule is loaded,
# watched going inactive -> pending -> firing under real load, and watched
# resolving afterwards. `for:` is the part people get wrong, and the only way
# to show you understand it is to catch the PENDING state on camera.
set -u
C="docker compose -f docker/docker-compose.yml"
PROM=http://127.0.0.1:9190
GRAF=http://127.0.0.1:3130
AUTH='admin:admin'
step()   { echo; echo "--- $* ---"; }
banner() { echo; echo "############ $* ############"; echo "EXAM_TOKEN: ${EXAM_TOKEN:-NOT SET} | $(date)"; }

banner "TASK 33  alerting"

step "syntax-check the rules with promtool BEFORE loading them"
$C exec -T prometheus promtool check rules /etc/prometheus/alert.rules.yml

step "reload prometheus without restarting it (--web.enable-lifecycle)"
curl -s -XPOST "$PROM/-/reload" </dev/null && echo "  reloaded"
sleep 3

step "rules prometheus has actually loaded"
curl -s "$PROM/api/v1/rules" </dev/null | tr ',' '\n' \
  | grep -E '"name"|"state"|"duration"|"health"' | sed 's/^/  /'

step "grafana-managed alert rule, provisioned from grafana/provisioning/alerting/"
curl -s -u "$AUTH" "$GRAF/api/v1/provisioning/alert-rules" </dev/null | tr ',' '\n' \
  | grep -E '"title"|"uid"|"folderUID"|"for"|severity' | sed 's/^/  /'

step "current alert state (expected: nothing firing)"
curl -s "$PROM/api/v1/alerts" </dev/null | tr '{' '\n' | grep -E '"alertname"|"state"' | sed 's/^/  /'
echo "  (empty = no alert is active)"

step "start load and watch the state machine"
nohup bash app/loadtest.sh http://127.0.0.1:3120 240 >/tmp/abdur-alert-load.log 2>&1 &
LOAD=$!
echo "  load started (pid $LOAD), sampling every 15s for 5 minutes"
echo
printf '  %-9s %-22s %-9s %s\n' TIME ALERT STATE VALUE
for i in $(seq 1 20); do
  OUT=$(curl -s "$PROM/api/v1/alerts" </dev/null | python3 -c '
import json,sys
d=json.load(sys.stdin)["data"]["alerts"]
if not d:
    print("  {:<9} {:<22} {:<9} {}".format("", "(none active)", "", ""))
for a in d:
    v = a.get("value","")
    # Format as a NUMBER. Slicing the string to 12 chars chopped the exponent
    # off "8.225108225108226e-02" and printed "8.2251082251" -- 8.2% rendered
    # as 822%. Same class of bug as the Grafana unit that turned 363 req/s
    # into "6.06 mins": the value was right and the rendering lied.
    try:    v = "{:.4g}".format(float(v))
    except Exception: pass
    print("  {:<9} {:<22} {:<9} {}".format(
        "", a["labels"].get("alertname","?") + " " + a["labels"].get("route",""),
        a["state"], v))' 2>/dev/null)
  echo "$(date +%T)$OUT"
  sleep 15
done
kill $LOAD 2>/dev/null; wait $LOAD 2>/dev/null

step "grafana's own view of the same rule"
curl -s -u "$AUTH" "$GRAF/api/prometheus/grafana/api/v1/rules" </dev/null | tr ',' '\n' \
  | grep -E '"name"|"state"|"health"' | sed 's/^/  /'

step "let it resolve"
echo "  load stopped; sampling for another 3 minutes"
for i in $(seq 1 12); do
  OUT=$(curl -s "$PROM/api/v1/alerts" </dev/null | python3 -c '
import json,sys
d=json.load(sys.stdin)["data"]["alerts"]
print("  (none active)" if not d else "  " + ", ".join(
    a["labels"].get("alertname","?")+"/"+a["labels"].get("route","")+"="+a["state"] for a in d))' 2>/dev/null)
  echo "$(date +%T)$OUT"
  sleep 15
done

echo; echo "############ task 33 complete ############"
