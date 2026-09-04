#!/usr/bin/env bash
# B4 task 38 -- deploy a broken v3 and watch Swarm roll back.
#
# v3 breaks by making /healthz return 500 (BREAK_HEALTHZ=1). The process stays
# UP; it just never becomes HEALTHY. That is deliberate: a task that exits is
# caught by the restart policy alone, whereas a task that runs but is useless is
# ONLY caught by a healthcheck -- which is exactly what the brief asks about.
#
# Phase B answers that question by experiment instead of by argument: the same
# broken image, deployed with --no-healthcheck.
set -u
STACK=abdur_notes
SVC=${STACK}_app
REG=${REG:-ghcr.io/rasel-xs}
URL=http://127.0.0.1:3140/healthz
LOG=evidence/b4-task38-traffic.txt
step()   { echo; echo "--- $* ---"; }
banner() { echo; echo "############ $* ############"; echo "EXAM_TOKEN: ${EXAM_TOKEN:-NOT SET} | $(date)"; }

traffic_on() {
  : > "$LOG"
  ( while true; do
      out=$(curl -s -w ' %{http_code}' --max-time 5 "$URL" </dev/null 2>/dev/null)
      printf '%s %s %s\n' "$(date +%T)" "${out##* }" \
        "$(printf '%s' "$out" | sed -n 's/.*"version":"\([^"]*\)".*/\1/p')"
      sleep 0.2
    done ) >> "$LOG" &
  LOOP=$!
}
traffic_off() { kill ${LOOP:-0} 2>/dev/null; sleep 1; }

banner "TASK 38  break v3, let swarm roll back"

step "starting state (should be v2, 5/5)"
docker service ls --filter name=$SVC --format 'table {{.Name}}\t{{.Replicas}}\t{{.Image}}'

# ═══════════════════════════════════ PHASE A ═══════════════════════════════
banner "PHASE A -- v3 WITH the healthcheck"

traffic_on
sleep 8

step "deploy the broken image"
T0=$(date +%s); echo "  t0 = $(date +%T)"
docker service update --detach --image "$REG/notes-api:v3" $SVC

step "poll -- watching for Failed / Rejected tasks and the rollback"
SAW_FAILED=0
for i in $(seq 1 90); do
  st=$(docker service inspect $SVC --format '{{if .UpdateStatus}}{{.UpdateStatus.State}}{{else}}none{{end}}')
  imgs=$(docker service ps $SVC --filter desired-state=running --format '{{.Image}}' | sed 's/.*://' | sort | uniq -c | tr '\n' ' ')
  bad=$(docker service ps $SVC --format '{{.CurrentState}}' | grep -ciE 'failed|rejected' || true)
  printf '  %s  state=%-20s running: %-16s failed/rejected: %s\n' "$(date +%T)" "$st" "$imgs" "$bad"
  if [ "$bad" -gt 0 ] && [ "$SAW_FAILED" -eq 0 ]; then
    SAW_FAILED=1
    echo
    echo "  >>> FAILED TASKS, caught live   [TASK 38 DELIVERABLE]"
    docker service ps $SVC --no-trunc \
      --format 'table {{.Name}}\t{{.Image}}\t{{.CurrentState}}\t{{.Error}}' \
      | sed 's|ghcr.io/rasel-xs/||' | head -12
    echo
  fi
  case "$st" in completed|rollback_completed|rollback_paused|paused) break ;; esac
  sleep 5
done
T1=$(date +%s)

step "UpdateStatus   [TASK 38 DELIVERABLE]"
docker service inspect $SVC --format '{{json .UpdateStatus}}' | python3 -m json.tool

step "final state -- should be back on v2   [TASK 38 DELIVERABLE]"
docker service ls --filter name=$SVC --format 'table {{.Name}}\t{{.Replicas}}\t{{.Image}}'
docker service ps $SVC --filter desired-state=running \
  --format 'table {{.Name}}\t{{.Image}}\t{{.CurrentState}}' | sed 's|ghcr.io/rasel-xs/||'

step "timing   [TASK 38 DELIVERABLE]"
docker service inspect $SVC --format 'StartedAt:   {{.UpdateStatus.StartedAt}}'
docker service inspect $SVC --format 'CompletedAt: {{.UpdateStatus.CompletedAt}}'
echo "  wall clock from my command to the poll seeing it finish: $((T1 - T0))s"

step "what did clients see during the failed deploy?"
traffic_off
awk '{print $2}' "$LOG" | sort | uniq -c | sort -rn | sed 's/^/    /'
awk '{print $3}' "$LOG" | sort | uniq -c | sort -rn | sed 's/^/    /'

# ═══════════════════════════════════ PHASE B ═══════════════════════════════
banner "PHASE B -- the same broken image, WITHOUT a healthcheck"
echo "  This is the brief's question, answered by experiment: if the image had"
echo "  no healthcheck, would Swarm have noticed that v3 is broken?"

traffic_on
sleep 8

step "deploy v3 again, with the healthcheck disabled"
T2=$(date +%s); echo "  t2 = $(date +%T)"
docker service update --detach --no-healthcheck --image "$REG/notes-api:v3" $SVC

step "poll"
for i in $(seq 1 60); do
  st=$(docker service inspect $SVC --format '{{if .UpdateStatus}}{{.UpdateStatus.State}}{{else}}none{{end}}')
  imgs=$(docker service ps $SVC --filter desired-state=running --format '{{.Image}}' | sed 's/.*://' | sort | uniq -c | tr '\n' ' ')
  bad=$(docker service ps $SVC --format '{{.CurrentState}}' | grep -ciE 'failed|rejected' || true)
  printf '  %s  state=%-20s running: %-16s failed/rejected: %s\n' "$(date +%T)" "$st" "$imgs" "$bad"
  case "$st" in completed|rollback_completed|rollback_paused|paused) break ;; esac
  sleep 5
done

step "UpdateStatus after the no-healthcheck deploy"
docker service inspect $SVC --format '{{json .UpdateStatus}}' | python3 -m json.tool

step "what is actually running, and does it work?"
docker service ls --filter name=$SVC --format 'table {{.Name}}\t{{.Replicas}}\t{{.Image}}'
echo "  curl /healthz -> $(curl -s -o /dev/null -w '%{http_code}' --max-time 5 "$URL" </dev/null)"
echo "  body: $(curl -s --max-time 5 "$URL" </dev/null)"

step "what clients saw   [the point of phase B]"
traffic_off
awk '{print $2}' "$LOG" | sort | uniq -c | sort -rn | sed 's/^/    /'

step "restore: redeploy the stack, which puts the healthcheck and v1 back"
REGISTRY="$REG" TAG=v1 docker stack deploy -c docker/stack.yml --with-registry-auth $STACK
sleep 45
docker service ls --filter name=$SVC --format 'table {{.Name}}\t{{.Replicas}}\t{{.Image}}'

echo; echo "############ task 38 complete ############"
