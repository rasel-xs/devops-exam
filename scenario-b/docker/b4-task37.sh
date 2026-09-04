#!/usr/bin/env bash
# B4 task 37 -- rolling update with zero downtime.
#
# One script rather than the brief's two terminals: the traffic loop runs in the
# background here, so the timing between "update issued" and "first v2 response"
# is measured rather than eyeballed across two windows.
#
# Each log line is  TIME  CODE  VERSION  HOST  -- all four come from ONE request,
# because /healthz returns {"status","version","host"} and -w appends the code.
# That means the version flip can be read off the same log that proves there was
# no downtime, instead of correlating two separate sources.
set -u
STACK=abdur_notes
SVC=${STACK}_app
REG=${REG:-ghcr.io/rasel-xs}
URL=http://127.0.0.1:3140/healthz
LOG=evidence/b4-task37-update-log.txt
step()   { echo; echo "--- $* ---"; }
banner() { echo; echo "############ $* ############"; echo "EXAM_TOKEN: ${EXAM_TOKEN:-NOT SET} | $(date)"; }

banner "TASK 37  rolling update v1 -> v2"

step "starting state"
docker service ls --filter name=$SVC --format 'table {{.Name}}\t{{.Replicas}}\t{{.Image}}'

step "traffic loop starts (5 req/s)"
: > "$LOG"
(
  while true; do
    out=$(curl -s -w ' %{http_code}' --max-time 5 "$URL" </dev/null 2>/dev/null)
    code=${out##* }
    ver=$(printf '%s' "$out" | sed -n 's/.*"version":"\([^"]*\)".*/\1/p')
    host=$(printf '%s' "$out" | sed -n 's/.*"host":"\([^"]*\)".*/\1/p')
    printf '%s %s %s %s\n' "$(date +%T)" "${code:-000}" "${ver:-NONE}" "${host:-NONE}"
    sleep 0.2
  done
) >> "$LOG" &
LOOP=$!
trap 'kill $LOOP 2>/dev/null' EXIT
sleep 12
echo "  baseline (12s before the update):"
awk '{print $2, $3}' "$LOG" | sort | uniq -c | sed 's/^/    /'

step "ISSUE THE UPDATE"
T0=$(date +%s)
echo "  t0 = $(date +%T)"
docker service update --detach --image "$REG/notes-api:v2" $SVC

step "watch it roll"
for i in $(seq 1 60); do
  st=$(docker service inspect $SVC --format '{{if .UpdateStatus}}{{.UpdateStatus.State}}{{else}}none{{end}}')
  running=$(docker service ps $SVC --filter desired-state=running --format '{{.Image}}' | sed 's/.*://' | sort | uniq -c | tr '\n' ' ')
  printf '  %s  state=%-12s tasks: %s\n' "$(date +%T)" "$st" "$running"
  case "$st" in completed|rollback_completed|paused|rollback_paused) break ;; esac
  sleep 5
done
T1=$(date +%s)

step "let traffic settle, then stop the loop"
sleep 10
kill $LOOP 2>/dev/null; trap - EXIT
sleep 1

step "UpdateStatus"
docker service inspect $SVC --format '{{json .UpdateStatus}}' | python3 -m json.tool

step "final state"
docker service ls --filter name=$SVC --format 'table {{.Name}}\t{{.Replicas}}\t{{.Image}}'
docker service ps $SVC --filter desired-state=running \
  --format 'table {{.Name}}\t{{.Image}}\t{{.CurrentState}}' | sed 's/ghcr.io\/rasel-xs\///'

step "STATUS CODE COUNT   [TASK 37 DELIVERABLE]"
awk '{print $2}' "$LOG" | sort | uniq -c | sort -rn

step "version served, over the whole run"
awk '{print $3}' "$LOG" | sort | uniq -c | sort -rn

step "the transition itself -- 10 lines either side of the first v2"
n=$(grep -n ' v2 ' "$LOG" | head -1 | cut -d: -f1)
if [ -n "${n:-}" ]; then
  sed -n "$(( n>10 ? n-10 : 1 )),$(( n+10 ))p" "$LOG" | sed 's/^/    /'
  first_v2=$(sed -n "${n}p" "$LOG" | awk '{print $1}')
  echo
  echo "  update issued at $(date -d "@$T0" +%T 2>/dev/null || echo '?')  |  first v2 response at $first_v2"
else
  echo "    no v2 response was ever logged -- the update did not take effect"
fi
echo "  rollout wall-clock: $((T1 - T0))s"

step "interleaving: were both versions serving at the same time?"
awk '{print $1, $3}' "$LOG" | uniq | awk '{print $2}' | uniq -c | sed 's/^/    /' | head -20

echo; echo "############ task 37 complete ############"
echo "log: $LOG"
