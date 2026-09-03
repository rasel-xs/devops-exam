#!/usr/bin/env bash
# B2 task 28, second follow-up. Two things the first follow-up left unresolved,
# plus one new suspicion it raised about our own compose file.
set -u
C="docker compose -f docker/docker-compose.yml"
IMG=abdur/notes-api:multi
step() { echo; echo "--- $* ---"; }
banner() { echo; echo "############ $* ############"; echo "EXAM_TOKEN: ${EXAM_TOKEN:-NOT SET} | $(date)"; }


banner "FU2-1  why the compose OOM survived and the docker-run OOM did not"
# Two candidate explanations, and they are distinguishable:
#   (a) SWAP. `docker run --memory=50m` sets memory-swap to 2x by default;
#       `deploy.resources.limits.memory` may leave swap unlimited, in which
#       case pages are swapped out instead of triggering the OOM killer.
#   (b) LAZY ZERO PAGES. Buffer.alloc() is guaranteed zeroed, and a large
#       zeroed allocation can be a fresh anonymous mmap -- virtual address
#       space that is never written to, so it never becomes resident and the
#       cgroup never charges it.
# (b) is testable directly: .fill(1) forces every page to be written.

ALLOC='const a=[];setInterval(()=>a.push(Buffer.alloc(10*1024*1024)),50)'
FILL='const a=[];setInterval(()=>a.push(Buffer.alloc(10*1024*1024).fill(1)),50)'

mem_test() {
  local name=$1 code=$2; shift 2
  docker rm -f "$name" >/dev/null 2>&1
  docker run -d --name "$name" "$@" "$IMG" node -e "$code" >/dev/null
  sleep 12
  printf '  %-22s status=%-9s exit=%-4s OOMKilled=%-6s mem=%s\n' \
    "$name" \
    "$(docker inspect --format='{{.State.Status}}'    "$name")" \
    "$(docker inspect --format='{{.State.ExitCode}}'  "$name")" \
    "$(docker inspect --format='{{.State.OOMKilled}}' "$name")" \
    "$(docker stats --no-stream --format '{{.MemUsage}}' "$name" 2>/dev/null || echo 'gone')"
  printf '  %-22s Memory=%s MemorySwap=%s\n' "" \
    "$(docker inspect --format='{{.HostConfig.Memory}}'     "$name")" \
    "$(docker inspect --format='{{.HostConfig.MemorySwap}}' "$name")"
  docker rm -f "$name" >/dev/null 2>&1
}

echo "  host swap:"; free -h | sed 's/^/    /'
step "plain docker run, Buffer.alloc only"
mem_test run-alloc "$ALLOC" --memory=50m
step "plain docker run, Buffer.alloc().fill(1)  -- forces the pages resident"
mem_test run-fill  "$FILL"  --memory=50m

step "compose: what swap setting does deploy.resources actually produce?"
$C -f docker/drills/28a-oom.yml up -d app >/dev/null 2>&1
sleep 12
CID=$($C -f docker/drills/28a-oom.yml ps -aq app)
docker inspect --format='  Status={{.State.Status}} OOMKilled={{.State.OOMKilled}} Memory={{.HostConfig.Memory}} MemorySwap={{.HostConfig.MemorySwap}} Swappiness={{.HostConfig.MemorySwappiness}}' "$CID"
docker stats --no-stream --format '  mem={{.MemUsage}} ({{.MemPerc}})' "$CID" 2>/dev/null
$C down >/dev/null 2>&1


banner "FU2-2  the nftables rule that drops cross-bridge traffic"
echo "  iptables backend: $(iptables --version 2>/dev/null)"
step "does the legacy view have anything?"
iptables -S 2>/dev/null | grep -ci isolation | sed 's/^/  matching lines: /'
step "nftables view"
nft list ruleset 2>/dev/null | grep -iA6 'isolation\|docker' | head -40 \
  || echo "  nft not available"
step "the bridges themselves"
ip -br link show type bridge | sed 's/^/  /'


banner "FU2-3  does OUR compose command forward SIGTERM?"
# `sh -c "a && b"` is compound, so sh cannot exec-replace itself; it stays as
# PID 1 and busybox sh does not forward signals to its child. If that is what
# happens, our graceful shutdown never runs under compose -- which matters in
# B4, where a rolling update stops tasks with SIGTERM.
$C up -d app >/dev/null 2>&1
sleep 12
step "what is PID 1 inside the app container?"
$C exec -T app ps -o pid,args 2>/dev/null | head -5
step "stop it and time how long it takes"
t0=$(date +%s)
$C stop -t 10 app >/dev/null
t1=$(date +%s)
CID=$($C ps -aq app)
printf '  exit=%s  stop took %ss\n' "$(docker inspect --format='{{.State.ExitCode}}' "$CID")" "$((t1-t0))"
step "did the app log its shutdown, or was it killed silently?"
docker logs "$CID" 2>&1 | tail -4
echo "  (a 'shutting down' line = the handler ran; ~10s and no line = sh ate the signal)"
$C down >/dev/null 2>&1

echo; echo "############ follow-up 2 complete ############"
