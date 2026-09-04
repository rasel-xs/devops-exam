#!/usr/bin/env bash
# B4 task 39 -- resource limits vs reservations.
#
# The two words describe two different machines:
#   limits       -> the cgroup the container runs inside     (runtime enforcement)
#   reservations -> what the scheduler must find free first  (placement only)
#
# So the same impossible number behaves in opposite ways, and this script asks
# for 16G on a ~7.8 GiB node BOTH ways to show it rather than assert it:
#   phase A  --limit-memory 16G    -> expected: accepted, deploys, runs fine
#   phase B  --reserve-memory 16G  -> expected: task never placed, stuck Pending
#
# A traffic loop runs throughout: while the update is wedged, do clients notice?
set -uo pipefail
cd "$(dirname "$0")/.."
SVC=abdur_notes_app
PORT=3140
TRAF=/tmp/t39-traffic.txt

poll_until_done() {   # $1 = label, $2 = max 10s rounds
  for i in $(seq 1 "$2"); do
    sleep 10
    st=$(docker service inspect $SVC --format '{{.UpdateStatus.State}}')
    rep=$(docker service ls --filter name=$SVC --format '{{.Replicas}}')
    echo "  $(date +%H:%M:%S)  $1  state=$st  replicas=$rep"
    [ "$st" = "completed" ] && return 0
  done
  return 1
}

echo "EXAM_TOKEN: ${EXAM_TOKEN:-unset} | $(date)"

echo
echo "=== 1. Swarm node e koto resource dekhe ==="
docker node inspect self --format \
  'host={{.Description.Hostname}}  nanocpus={{.Description.Resources.NanoCPUs}}  membytes={{.Description.Resources.MemoryBytes}}'
docker node inspect self --format '{{.Description.Resources.MemoryBytes}}' \
  | awk '{printf "  schedulable memory = %.2f GiB\n", $1/1073741824}'
free -g | head -2

echo
echo "=== 2. ekhonkar Resources spec ==="
docker service inspect $SVC --format '{{json .Spec.TaskTemplate.Resources}}' | python3 -m json.tool

echo
echo "=== 3. traffic loop chalu ==="
( for i in $(seq 1 400); do
    printf '%s ' "$(date +%H:%M:%S)"
    curl -s -o /dev/null -w '%{http_code}\n' --max-time 3 "http://127.0.0.1:$PORT/healthz"
    sleep 1
  done ) > "$TRAF" 2>&1 &
TRAFFIC=$!

echo
echo "############ PHASE A: LIMIT 16G (cgroup cap, node capacity er cheye boro) ############"
docker service update --limit-memory 16G --detach $SVC
echo "issued at $(date +%H:%M:%S)"
poll_until_done "limit16G" 12 || echo "  (12 round e sesh hoyni)"
echo "--- container er bhitor cgroup ki bolche? ---"
cid=$(docker ps -q --filter "name=${SVC}." | head -1)
if [ -n "$cid" ]; then
  docker exec "$cid" sh -c 'cat /sys/fs/cgroup/memory.max 2>/dev/null || cat /sys/fs/cgroup/memory/memory.limit_in_bytes' \
    | awk '{printf "  memory.max = %s  (= %.2f GiB)\n", $1, $1/1073741824}'
fi
docker service ps $SVC --no-trunc --format '  {{.Name}} {{.DesiredState}} {{.CurrentState}}' | head -4

echo
echo "############ PHASE B: RESERVE 16G (scheduler ke 16G khuje dite hobe) ############"
docker service update --reserve-memory 16G --detach $SVC
echo "issued at $(date +%H:%M:%S)"
for i in 1 2 3 4 5; do
  sleep 10
  echo "--- $(date +%H:%M:%S) ---"
  docker service ls --filter name=$SVC --format '  ls: {{.Name}} {{.Replicas}}'
  docker service ps $SVC --no-trunc \
    --format '  {{.Name}}  desired={{.DesiredState}}  current={{.CurrentState}}  err={{.Error}}' | head -6
done

echo
echo "=== je task ta bosano jayni ==="
docker service ps $SVC --no-trunc --filter 'desired-state=ready' \
  --format 'table {{.ID}}\t{{.Node}}\t{{.DesiredState}}\t{{.CurrentState}}\t{{.Error}}'
pid=$(docker service ps $SVC --filter 'desired-state=ready' --format '{{.ID}}' | head -1)
[ -n "$pid" ] && { echo "--- task $pid ---"; docker inspect "$pid" --format '{{json .Status}}' | python3 -m json.tool; }

echo
echo "=== UpdateStatus (Swarm ki 'completed' bolche, na atke ache?) ==="
docker service inspect $SVC --format '{{json .UpdateStatus}}' | python3 -m json.tool

echo
echo "############ UNDO: duitai stack.yml er mane fera ############"
docker service update --limit-memory 256M --reserve-memory 128M --detach $SVC
poll_until_done "undo" 12 || echo "  (12 round e sesh hoyni)"
docker service inspect $SVC --format '{{json .Spec.TaskTemplate.Resources}}' | python3 -m json.tool

kill $TRAFFIC 2>/dev/null; wait $TRAFFIC 2>/dev/null
echo
echo "=== purota somoy client ra ki peyeche ==="
awk '{print $2}' "$TRAF" | sort | uniq -c
