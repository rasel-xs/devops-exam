#!/usr/bin/env bash
# B2 task 28 follow-up. Three of my predictions in run-drills.sh were wrong.
# This script establishes WHY, instead of me asserting an explanation.
set -u
C="docker compose -f docker/docker-compose.yml"
IMG=abdur/notes-api:multi
step() { echo; echo "--- $* ---"; }
banner() { echo; echo "############ $* ############"; echo "EXAM_TOKEN: ${EXAM_TOKEN:-NOT SET} | $(date)"; }


banner "FU-1  why 'docker stop' gave 137 instead of 143"
# Hypothesis: the kernel does not apply DEFAULT signal actions to PID 1. A
# process with no SIGTERM handler that happens to be PID 1 simply ignores it,
# docker's grace period expires, and SIGKILL (137) follows. Three variants,
# identical except for what sits at PID 1 / whether a handler exists.

run_stop_test() {
  local name=$1; shift
  docker rm -f "$name" >/dev/null 2>&1
  docker run -d --name "$name" "$@" >/dev/null
  sleep 2
  local t0 t1
  t0=$(date +%s)
  docker stop -t 5 "$name" >/dev/null
  t1=$(date +%s)
  printf '  %-28s exit=%-4s  stop took %ss\n' \
    "$name" \
    "$(docker inspect --format='{{.State.ExitCode}}' "$name")" \
    "$((t1 - t0))"
  docker rm -f "$name" >/dev/null 2>&1
}

echo "  (stop took ~5s = the grace period expired = the signal was ignored)"
echo "  (stop took ~0s = the process handled SIGTERM and left)"
run_stop_test pid1-no-handler   "$IMG" node -e 'setInterval(()=>{},1000)'
run_stop_test pid1-with-handler "$IMG" node -e 'process.on("SIGTERM",()=>process.exit(0));setInterval(()=>{},1000)'
run_stop_test tini-init         --init "$IMG" node -e 'setInterval(()=>{},1000)'
run_stop_test not-pid1-shell    "$IMG" sh -c 'node -e "setInterval(()=>{},1000)"'

step "and our REAL server, which does install a handler"
docker rm -f real-server >/dev/null 2>&1
docker run -d --name real-server "$IMG" >/dev/null
sleep 3
t0=$(date +%s); docker stop -t 10 real-server >/dev/null; t1=$(date +%s)
printf '  %-28s exit=%-4s  stop took %ss\n' "real-server" \
  "$(docker inspect --format='{{.State.ExitCode}}' real-server)" "$((t1-t0))"
docker logs real-server 2>&1 | tail -3
docker rm -f real-server >/dev/null 2>&1


banner "FU-2  did the compose OOM drill actually die?"
$C -f docker/drills/28a-oom.yml up -d app >/dev/null 2>&1
sleep 20
CID=$($C -f docker/drills/28a-oom.yml ps -aq app)
step "state, and what command it is ACTUALLY running"
docker inspect --format='Status={{.State.Status}}  ExitCode={{.State.ExitCode}}  OOMKilled={{.State.OOMKilled}}  Restarts={{.RestartCount}}' "$CID"
docker inspect --format='Cmd={{json .Config.Cmd}}'  "$CID"
docker inspect --format='Entrypoint={{json .Config.Entrypoint}}' "$CID"
docker inspect --format='MemoryLimit={{.HostConfig.Memory}}' "$CID"
step "its logs"
docker logs "$CID" 2>&1 | tail -8
step "live memory usage against the limit"
docker stats --no-stream --format '  {{.Name}}  {{.MemUsage}}  {{.MemPerc}}' "$CID" 2>/dev/null
$C down >/dev/null 2>&1


banner "FU-3  why the IP was unreachable across bridges"
# I claimed the IP would still route and only the NAME would fail. It timed
# out. Docker enforces bridge-to-bridge isolation in iptables.
$C up -d postgres >/dev/null 2>&1
sleep 5
PGIP=$(docker inspect --format='{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' "$($C ps -q postgres)")
echo "  postgres = $PGIP"
step "the iptables chain that drops it"
iptables -S DOCKER-ISOLATION-STAGE-1 2>/dev/null | head -8
iptables -S DOCKER-ISOLATION-STAGE-2 2>/dev/null | head -8
step "timed out (DROP) or refused (RST)? -- same question as Scenario A task 8"
docker run --rm --network bridge "$IMG" node -e "
  const net=require('net'), s=net.connect(5432,'$PGIP');
  const t0=Date.now(), done=(m)=>{console.log('  '+m+'  after '+(Date.now()-t0)+'ms');process.exit(0)};
  s.on('connect',()=>done('CONNECTED'));
  s.on('error',e=>done('error '+e.code));
  setTimeout(()=>done('still hanging -> packets are being DROPPED, not refused'),4000);"
$C down >/dev/null 2>&1


banner "FU-4  why curl said 56 and not 7"
# 7 = refused (something sent a RST). 56 = the connection was ESTABLISHED and
# then failed while receiving. docker-proxy accepts on the host port first.
$C -f docker/drills/28d-loopback.yml up -d app >/dev/null 2>&1
sleep 10
step "who is listening on the HOST side of 3120"
ss -lntp 2>/dev/null | grep 3120 || netstat -lntp 2>/dev/null | grep 3120
step "curl, verbose, so the accept-then-die is visible"
curl -sv -m 5 http://127.0.0.1:3120/healthz </dev/null 2>&1 | grep -E 'Trying|Connected|Recv failure|Empty reply|curl:' | head
echo "  curl exit = $(curl -s -m 5 -o /dev/null http://127.0.0.1:3120/healthz </dev/null; echo $?)"
step "CONTROL: a port with nothing on it at all -> exit 7, instantly"
curl -s -m 5 -o /dev/null http://127.0.0.1:3199/healthz </dev/null; echo "  exit = $?"
$C down >/dev/null 2>&1

echo; echo "############ follow-up complete ############"
