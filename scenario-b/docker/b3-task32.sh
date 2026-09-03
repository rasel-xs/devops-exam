#!/usr/bin/env bash
# B3 task 32 -- the dashboard. Checked three ways:
#   1. Grafana is healthy and has the provisioned datasource and dashboard
#   2. the datasource can actually reach Prometheus (Grafana's own health probe)
#   3. every panel query resolves to real data
set -u
GRAF=http://127.0.0.1:3130
PROM=http://127.0.0.1:9190
AUTH='admin:admin'
step()   { echo; echo "--- $* ---"; }
banner() { echo; echo "############ $* ############"; echo "EXAM_TOKEN: ${EXAM_TOKEN:-NOT SET} | $(date)"; }

banner "TASK 32  Grafana dashboard"

step "grafana health"
curl -s "$GRAF/api/health" </dev/null; echo

step "provisioned datasource"
curl -s -u "$AUTH" "$GRAF/api/datasources" </dev/null \
  | tr '{' '\n' | grep -E '"name"|"uid"|"url"|"type"' | sed 's/^/  /'

step "can grafana actually reach prometheus through it?"
DSID=$(curl -s -u "$AUTH" "$GRAF/api/datasources/name/Prometheus" </dev/null \
       | tr ',' '\n' | grep '"uid"' | head -1 | cut -d'"' -f4)
echo "  datasource uid = $DSID"
curl -s -u "$AUTH" "$GRAF/api/datasources/uid/$DSID/health" </dev/null | sed 's/^/  /'; echo

step "provisioned dashboards"
curl -s -u "$AUTH" "$GRAF/api/search?query=%25" </dev/null \
  | tr '{' '\n' | grep -E '"title"|"uid"|"type"' | sed 's/^/  /'

step "generate 90s of load so the panels have something to draw"
bash app/loadtest.sh http://127.0.0.1:3120 90 >/dev/null 2>&1 &
LOADPID=$!
sleep 95
wait $LOADPID 2>/dev/null

step "every panel query, evaluated against Prometheus"
python3 docker/b3-panels.py "$PROM" 1m

echo
echo "############ task 32 complete ############"
echo "Now open the dashboard in a browser and screenshot it:"
echo "  http://169.58.246.108:3130   (admin / admin)"
