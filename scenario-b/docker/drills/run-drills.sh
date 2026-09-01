#!/usr/bin/env bash
# B2 task 28 -- cause, then diagnose, each of the four failures.
# Run from scenario-b/:  bash docker/drills/run-drills.sh 2>&1 | tee evidence/b2-drills.txt
set -u
C="docker compose -f docker/docker-compose.yml"
banner() { echo; echo "############ $* ############"; echo "EXAM_TOKEN: ${EXAM_TOKEN:-NOT SET} | $(date)"; }

banner "28a  exit 137 / OOMKilled"
docker run --memory=50m --rm python:3-alpine python -c "x=[0]*100000000" ; echo "exit=$?"
$C -f docker/drills/28a-oom.yml up -d app; sleep 20
CID=$($C ps -q app)
echo "--- the command that reveals the cause ---"
docker inspect --format='ExitCode={{.State.ExitCode}} OOMKilled={{.State.OOMKilled}}' "$CID"
docker inspect --format='{{.HostConfig.Memory}}' "$CID"
$C down >/dev/null 2>&1

banner "28b  service name does not resolve"
$C -f docker/drills/28b-dns.yml up -d; sleep 10
echo "--- networks each container is on ---"
docker network ls
$C ps -q | while read -r c; do
  printf '%s %s\n' "$(docker inspect --format='{{.Name}}' "$c")" \
    "$(docker inspect --format='{{range $k,$v := .NetworkSettings.Networks}}{{$k}} {{$v.IPAddress}} {{end}}' "$c")"
done
echo "--- the command that reveals the cause ---"
$C exec -T app getent hosts postgres || echo "  getent: name does not resolve  <-- root cause"
$C down >/dev/null 2>&1

banner "28c  bind mount shadows the image contents"
$C -f docker/drills/28c-mount-shadow.yml up -d app; sleep 8
$C logs app | tail -5
echo "--- the command that reveals the cause ---"
$C exec -T app ls -la /app/node_modules 2>&1 | head -3
docker inspect --format='{{json .Mounts}}' "$($C ps -aq app)" | head -c 600; echo
$C down >/dev/null 2>&1

banner "28d  published port, connection refused"
$C -f docker/drills/28d-loopback.yml up -d app; sleep 8
$C ps
echo "--- from the host ---"
curl -s -m 3 -o /dev/null -w 'host curl -> HTTP %{http_code}\n' http://localhost:3000/healthz \
  || echo "  curl exit $? -- 7 = connection refused  <-- symptom"
echo "--- from inside the container ---"
$C exec -T app wget -qO- http://127.0.0.1:3000/healthz && echo "  works INSIDE  <-- root cause is the bind address"
echo "--- the command that reveals the cause ---"
$C exec -T app netstat -lntp 2>/dev/null || $C exec -T app sh -c 'cat /proc/net/tcp | head -3'
$C down >/dev/null 2>&1
echo; echo "drills complete"
