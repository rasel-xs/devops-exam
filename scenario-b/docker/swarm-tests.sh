#!/usr/bin/env bash
# B4 evidence generator. Run on the swarm manager.
#   echo "$EXAM_TOKEN | $(date)"; bash docker/swarm-tests.sh
set -u
echo "EXAM_TOKEN: ${EXAM_TOKEN:-NOT SET} | $(date)"; echo

echo "=== task 35: stack and nodes ==="
docker node ls
docker stack services notes
echo

echo "=== task 36: scale to 5 and prove all 5 serve traffic ==="
docker service scale notes_app=5
sleep 20
docker service ps notes_app --format 'table {{.Name}}\t{{.Node}}\t{{.CurrentState}}'
echo "--- which replica answered? ---"
# `Connection: close` matters: without it curl reuses one keep-alive connection,
# the routing mesh keeps sending it to the same task, and you see ONE hostname
# and conclude scaling is broken.
for i in $(seq 1 50); do
  curl -s -o /dev/null -D - -H "Connection: close" http://localhost:3000/healthz \
    | grep -i '^X-Served-By'
done | sort | uniq -c
echo

echo "=== task 37: rolling update -- run the traffic loop in ANOTHER terminal first ==="
cat <<'LOOP'
  while true; do
    printf "%s %s\n" "$(date +%T)" \
      "$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 http://localhost:3000/healthz)"
    sleep 0.2
  done | tee update-log.txt
  # then:  docker service update --image $REG/notes-api:v2 notes_app
  # then:  awk '{print $2}' update-log.txt | sort | uniq -c
LOOP
echo

echo "=== task 38: break v3 and watch the rollback ==="
cat <<'ROLL'
  docker service update --image $REG/notes-api:v3 notes_app
  watch -n1 'docker service ps notes_app --no-trunc | head -20'
  docker service inspect notes_app --format '{{json .UpdateStatus}}' | jq
  # time it: compare the StartedAt in UpdateStatus with CompletedAt
ROLL
echo

echo "=== task 39: reservation the node cannot satisfy ==="
echo "  docker service update --reserve-memory 8G notes_app"
echo "  docker service ps notes_app --no-trunc     # 'no suitable node' / Pending"
echo "  docker service update --reserve-memory 128M notes_app   # undo"
echo

echo "=== task 40: scale down under live traffic ==="
echo "  (traffic loop still running)  docker service scale notes_app=2"
echo "  awk '{print \$2}' update-log.txt | sort | uniq -c"
