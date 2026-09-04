#!/usr/bin/env bash
# B4 task 40 -- scale 5 -> 2 while traffic is running.
#
# Counting failures alone would not explain anything, so this runs TWO clients
# at once and the difference between them IS the finding (same split as task 36):
#
#   A  Connection: close   -> a fresh TCP connection per request. The routing
#                             mesh re-picks a task every time, so it should
#                             never land on one that is going away.
#   B  keep-alive          -> a connection pinned to one task. If that task is
#                             one of the three being removed, this client is
#                             holding a socket to a process that is shutting
#                             down. num_connects tells us when the socket died.
#
# Prediction to be checked against the output: A stays clean; B survives too,
# but only because server.close() lets in-flight requests finish and Node then
# marks the response Connection: close, forcing B to reconnect. The evidence for
# that claim is num_connects going 0,0,0,...,1 at the moment of the scale-down.
set -uo pipefail
cd "$(dirname "$0")/.."
SVC=abdur_notes_app
PORT=3140
A=/tmp/t40-close.txt
B=/tmp/t40-keepalive.txt

ts() { date '+%H:%M:%S.%3N'; }
count_running() { docker service ps $SVC --filter 'desired-state=running' \
                  --format '{{.CurrentState}}' | grep -c '^Running' || true; }

echo "EXAM_TOKEN: ${EXAM_TOKEN:-unset} | $(date)"
echo "curl: $(curl --version | head -1)"

echo
echo "=== 1. 3 -> 5 e scale (brief 5 theke soru korte bole) ==="
docker service scale $SVC=5 --detach
for i in $(seq 1 15); do
  sleep 10
  r=$(docker service ls --filter name=$SVC --format '{{.Replicas}}')
  echo "  $(date +%H:%M:%S) replicas=$r running_tasks=$(count_running)"
  [ "$r" = "5/5" ] && break
done

echo
echo "=== 2. scale-down er AGE kon container gulo chole ==="
docker ps --filter "name=${SVC}." --format '  {{.ID}}  {{.Names}}' | tee /tmp/t40-before.txt

echo
echo "=== 3. duita client chalu, 20s baseline ==="
# client A: fresh connection each request
( while :; do
    printf '%s ' "$(ts)"
    curl -s -o /dev/null -H 'Connection: close' \
         -w '%{http_code} %{num_connects}\n' --max-time 5 "http://127.0.0.1:$PORT/healthz" \
      || echo "000 curl-exit-$?"
  done ) > "$A" 2>&1 &
PA=$!

# client B: 40 requests down ONE reused connection per batch, one batch per second
( urls=""; for i in $(seq 1 40); do urls="$urls http://127.0.0.1:$PORT/healthz"; done
  while :; do
    printf '%s\n' "--- batch $(ts) ---"
    curl -s -o /dev/null -w '%{http_code} conn=%{num_connects}\n' --max-time 5 $urls \
      || echo "000 curl-exit-$?"
    sleep 1
  done ) > "$B" 2>&1 &
PB=$!

sleep 20

echo
echo "=== 4. SCALE DOWN 5 -> 2 ==="
T0=$(ts); echo "  scale issued at $T0"
docker service scale $SVC=2 --detach
for i in $(seq 1 20); do
  sleep 3
  r=$(docker service ls --filter name=$SVC --format '{{.Replicas}}')
  echo "  $(date +%H:%M:%S) replicas=$r running_tasks=$(count_running)"
  [ "$r" = "2/2" ] && break
done
echo "  converged at $(ts)"

sleep 10
kill $PA $PB 2>/dev/null; wait $PA $PB 2>/dev/null

echo
echo "=== 5. je container gulo bondho holo, tara ki SIGTERM peyechilo? ==="
while read -r _ cid name; do
  [ -z "${cid:-}" ] && continue
  if ! docker ps -q --no-trunc | grep -q "^$cid"; then
    echo "--- $name ($cid) STOPPED ---"
    docker logs "$cid" 2>&1 | grep -i 'shutting down\|listening' | tail -3
    docker inspect "$cid" --format '  exit={{.State.ExitCode}} oom={{.State.OOMKilled}}' 2>/dev/null
  fi
done < /tmp/t40-before.txt

echo
echo "=== 6. CLIENT A (Connection: close) ==="
echo "  code count:"
awk '{print $2}' "$A" | sort | uniq -c | sed 's/^/    /'
echo "  mot request: $(wc -l < "$A")"
echo "  T0=$T0 er por-er prothom 15 ta line:"
awk -v t0="$T0" '$1 >= t0 && c < 15 {print "    " $0; c++}' "$A"
echo "  non-200 line gulo:"
awk '$2 != 200 {print "    " $0}' "$A" | head -20

echo
echo "=== 7. CLIENT B (keep-alive) ==="
echo "  code count:"
grep -v '^---' "$B" | awk '{print $1}' | sort | uniq -c | sed 's/^/    /'
echo "  connection count (conn=0 mane socket reuse hoyeche):"
grep -v '^---' "$B" | awk '{print $2}' | sort | uniq -c | sed 's/^/    /'
echo "  jei batch e notun connection lagse (conn=1), sei batcher somoy:"
awk '/^--- batch/{b=$3} /conn=1/{print "    " b "  " $0}' "$B" | head -20
echo "  non-200 line gulo:"
grep -v '^---' "$B" | grep -v '^200 ' | head -20 || echo "    (kichu nei)"

echo "=== 8. 3 replicas e fera (stack.yml er man) ==="
docker service scale $SVC=3 --detach
sleep 5
docker service ls --filter name=$SVC
