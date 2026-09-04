#!/usr/bin/env bash
# task 40 follow-up. Prothom run e duita jinis miss holo:
#   (a) keep-alive socket ta scale-down par hoyni -- proti batch e notun curl
#       process chilo, tai socket matro ~1s tikto.
#   (b) 'stopped' detection ulto chilo (read -r _ cid name, leading space).
# Ekhane: 3 ta client, protyek ta EKTA curl process, EKTA socket, 40s dhore --
# tai kono na kono ekta nishchoi doomed task e pin hobe.
set -uo pipefail
cd "$(dirname "$0")/.."
SVC=abdur_notes_app
PORT=3140
ts() { date '+%H:%M:%S.%3N'; }

echo "EXAM_TOKEN: ${EXAM_TOKEN:-unset} | $(date)"

echo "=== 1. 5 e scale ==="
docker service scale $SVC=5 --detach
for i in $(seq 1 15); do
  sleep 8
  r=$(docker service ls --filter name=$SVC --format '{{.Replicas}}')
  echo "  $(date +%H:%M:%S) replicas=$r"
  [ "$r" = "5/5" ] && break
done

docker ps --filter "name=${SVC}." --format '{{.ID}}|{{.Names}}' > /tmp/t40b-before.txt
echo
echo "=== 2. scale-down er age ja cholche ==="
cat /tmp/t40b-before.txt

echo
echo "=== 3. 3 ta pinned client -- ekta kore socket, 400 request @10/s ==="
args=""; for i in $(seq 1 400); do args="$args http://127.0.0.1:$PORT/healthz"; done
PIDS=""
for c in 1 2 3; do
  ( curl -s --rate 10/s --max-time 120 \
        -w '|%{http_code}|conn=%{num_connects}\n' $args ) > "/tmp/t40b-c$c.txt" 2>&1 &
  PIDS="$PIDS $!"
done
echo "  started at $(ts), pids:$PIDS"

sleep 15
echo
echo "=== 4. SCALE 5 -> 2 ==="
T0=$(ts); echo "  issued at $T0"
docker service scale $SVC=2 --detach
for i in $(seq 1 25); do
  sleep 2
  r=$(docker service ls --filter name=$SVC --format '{{.Replicas}}')
  n=$(docker ps -q --filter "name=${SVC}." | wc -l)
  echo "  $(ts) replicas=$r live_containers=$n"
  [ "$r" = "2/2" ] && break
done
echo "  converged at $(ts)"
for p in $PIDS; do wait "$p" 2>/dev/null; done

echo
echo "=== 5. je container gulo SORANO holo -- SIGTERM handle korlo ki? ==="
while IFS='|' read -r cid name; do
  [ -z "${cid:-}" ] && continue
  if docker ps -q --no-trunc | grep -q "^${cid}"; then
    echo "--- $name : EKHONO CHOLCHE (survivor)"
  else
    echo "--- $name : SORANO HOYECHE"
    docker logs "$cid" 2>&1 | grep -i 'shutting down' | sed 's/^/    /' || true
    docker inspect "$cid" --format \
      '    exit={{.State.ExitCode}} oom={{.State.OOMKilled}} started={{.State.StartedAt}} finished={{.State.FinishedAt}}' \
      2>/dev/null || echo "    (container muche fela hoyeche)"
  fi
done < /tmp/t40b-before.txt

echo
echo "=== 6. FOLAFOL (T0=$T0) ==="
for c in 1 2 3; do
  f="/tmp/t40b-c$c.txt"
  echo "--- client $c : $(wc -l < "$f") line ---"
  echo "  status:"; awk -F'|' '{print $2}' "$f" | sort | uniq -c | sed 's/^/     /'
  echo "  socket:"; awk -F'|' '{print $3}' "$f" | sort | uniq -c | sed 's/^/     /'
  echo "  kon container serve korlo (poroporo run):"
  grep -o '"host":"[^"]*"' "$f" | uniq -c | sed 's/^/     /'
  echo "  non-200:"
  awk -F'|' '$2 !~ /^200$/ {print "     " $0}' "$f" | head -5 || echo "     (nei)"
done

echo
echo "=== 7. 3 e fera ==="
docker service scale $SVC=3 --detach
