#!/usr/bin/env bash
# B2 task 28 -- cause each of four failures deliberately, then diagnose it.
# Run from scenario-b/:
#   bash docker/drills/run-drills.sh 2>&1 | tee evidence/b2-drills.txt
#
# No `set -e`: every drill must run even when an earlier one fails, because a
# failing command IS the evidence here.
set -u

C="docker compose -f docker/docker-compose.yml"
IMG=abdur/notes-api:multi
APP_PORT=3120          # the app is published on 3120, NOT 3000. 3000 is the
                       # port INSIDE the container.

banner() { echo; echo "############ $* ############"; echo "EXAM_TOKEN: ${EXAM_TOKEN:-NOT SET} | $(date)"; }
step()   { echo; echo "--- $* ---"; }

$C down --remove-orphans >/dev/null 2>&1


# ─────────────────────────────────────────────────────────────────────────────
banner "28a  container exits with code 137"

step "SYMPTOM: minimal repro, a 50 MB limit and a process that wants more"
docker rm -f abdur-oom >/dev/null 2>&1
docker run -d --name abdur-oom --memory=50m "$IMG" \
  node -e 'const a=[];setInterval(()=>a.push(Buffer.alloc(10*1024*1024)),20)' >/dev/null
echo "exit code = $(docker wait abdur-oom)"

step "DIAGNOSIS: the one field that separates OOM from every other 137"
docker inspect --format='ExitCode={{.State.ExitCode}}  OOMKilled={{.State.OOMKilled}}  MemoryLimit={{.HostConfig.Memory}}' abdur-oom

step "CONTROL 1: docker kill also gives 137 -- so 137 alone proves nothing"
docker rm -f abdur-killed >/dev/null 2>&1
docker run -d --name abdur-killed "$IMG" node -e 'setInterval(()=>{},1000)' >/dev/null
sleep 2; docker kill abdur-killed >/dev/null
docker inspect --format='ExitCode={{.State.ExitCode}}  OOMKilled={{.State.OOMKilled}}' abdur-killed

step "CONTROL 2: a polite stop gives 143, not 137"
docker rm -f abdur-stopped >/dev/null 2>&1
docker run -d --name abdur-stopped "$IMG" node -e 'setInterval(()=>{},1000)' >/dev/null
sleep 2; docker stop -t 2 abdur-stopped >/dev/null
docker inspect --format='ExitCode={{.State.ExitCode}}  OOMKilled={{.State.OOMKilled}}' abdur-stopped

step "the same thing through compose, to prove deploy.resources is honoured"
# NOT `sleep 15`. An earlier version of this script slept a fixed 15s, found
# the container still running, and concluded that compose ignores the memory
# limit. It does not: `Buffer.alloc()` without a write leaves the pages
# unmapped, so the cgroup charge climbs slowly and the OOM took 87 SECONDS.
# `.fill(1)` does the same thing in under one. A fixed sleep in a test can
# invert its conclusion; wait for the event instead.
$C -f docker/drills/28a-oom.yml up -d app >/dev/null 2>&1
OOMCID=$($C -f docker/drills/28a-oom.yml ps -aq app)     # -a: it is DEAD, -q alone would miss it
echo "  waiting for it to die (this takes ~90s with alloc-only)..."
timeout 180 docker wait "$OOMCID" >/dev/null 2>&1 || echo "  still alive after 180s"
docker inspect --format='ExitCode={{.State.ExitCode}}  OOMKilled={{.State.OOMKilled}}  MemoryLimit={{.HostConfig.Memory}}  Restarts={{.RestartCount}}' "$OOMCID"
docker rm -f abdur-oom abdur-killed abdur-stopped >/dev/null 2>&1
$C down >/dev/null 2>&1


# ─────────────────────────────────────────────────────────────────────────────
banner "28b  the app cannot resolve the database by name"

# The compose override in 28b-dns.yml needs `!reset`, which is Compose v2.24+.
# On an older Compose the override MERGES instead of replacing and the app ends
# up on both networks, DNS works, and the drill silently proves nothing. So the
# proof here is a version-proof A/B with plain `docker run` on three networks.
echo "compose version: $(docker compose version --short 2>/dev/null)"
$C up -d postgres >/dev/null 2>&1
sleep 5
DEFNET=$(docker inspect --format='{{range $k,$v := .NetworkSettings.Networks}}{{$k}}{{end}}' "$($C ps -q postgres)")
PGIP=$(docker inspect --format='{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' "$($C ps -q postgres)")
echo "postgres is on network '$DEFNET' at $PGIP"

# `getent` and `nc` are busybox applets that are not guaranteed to be present;
# if one were missing the `||` branch would print "does not resolve" and I would
# draw the wrong conclusion from a missing binary. Node is definitely in the
# image, so the lookups go through node's dns.lookup (getaddrinfo -> the
# container's own resolver), which is the same path the app itself uses.
dnstest() {
  docker run --rm --network "$1" "$IMG" node -e \
    "require('dns').lookup('postgres',(e,a)=>{console.log(e?'  LOOKUP FAILED: '+e.code:'  postgres -> '+a)})"
}

step "A: same user-defined network as postgres  -> name SHOULD resolve"
dnstest "$DEFNET"

step "B: the legacy default 'bridge' network -> NO service discovery at all"
dnstest bridge
echo "  ^ ENOTFOUND here is the ROOT CAUSE of this drill"

step "C: a different user-defined network -> also no resolution"
docker network create abdur-isolated >/dev/null 2>&1
dnstest abdur-isolated

step "but the IP still routes from the default bridge (name != reachability)"
docker run --rm --network bridge "$IMG" node -e "
  const net=require('net'), s=net.connect(5432,'$PGIP');
  const done=(m,c)=>{console.log(m);process.exit(c)};
  s.on('connect',()=>done('  TCP to $PGIP:5432 OK -- so it is DNS, not the network',0));
  s.on('error',e=>done('  TCP failed: '+e.code,1));
  setTimeout(()=>done('  TCP timed out',1),3000);"

step "who is on which network"
docker network inspect "$DEFNET" --format '{{range .Containers}}{{.Name}} {{.IPv4Address}}
{{end}}'
step "the resolver every container talks to"
docker run --rm --network "$DEFNET" "$IMG" cat /etc/resolv.conf
docker network rm abdur-isolated >/dev/null 2>&1
$C down >/dev/null 2>&1


# ─────────────────────────────────────────────────────────────────────────────
banner "28c  volume mounted, the app sees an empty directory"

mkdir -p docker/drills/empty-folder
echo "host dir contents: $(ls -A docker/drills/empty-folder | wc -l) entries (a .gitkeep, so git tracks the dir)"

step "SYMPTOM: start the app with an empty host dir over /app/node_modules"
$C -f docker/drills/28c-mount-shadow.yml up -d app >/dev/null 2>&1
sleep 8
$C -f docker/drills/28c-mount-shadow.yml logs app 2>&1 | tail -6

step "DIAGNOSIS: the container is crash-looping, so exec will not work --"
echo "    use a throwaway container with the SAME mount instead"
docker run --rm -v "$PWD/docker/drills/empty-folder":/app/node_modules "$IMG" \
  sh -c 'echo "  /app/node_modules -> $(ls -A /app/node_modules | wc -l) entries"'

step "the same image WITHOUT the mount, to prove the files exist in the image"
docker run --rm "$IMG" sh -c 'echo "  /app/node_modules -> $(ls -A /app/node_modules | wc -l) entries"'

step "what docker says it mounted"
docker inspect --format='{{range .Mounts}}{{.Type}} {{.Source}} -> {{.Destination}}
{{end}}' "$($C -f docker/drills/28c-mount-shadow.yml ps -aq app)"

step "CONTRAST: a NAMED volume copies the image contents in on first use"
docker volume rm abdur-nm-demo >/dev/null 2>&1
docker volume create abdur-nm-demo >/dev/null
docker run --rm -v abdur-nm-demo:/app/node_modules "$IMG" \
  sh -c 'echo "  named volume, first use -> $(ls -A /app/node_modules | wc -l) entries"'
docker volume rm abdur-nm-demo >/dev/null 2>&1
$C down >/dev/null 2>&1


# ─────────────────────────────────────────────────────────────────────────────
banner "28d  port published, connection refused from the host"

$C -f docker/drills/28d-loopback.yml up -d app >/dev/null 2>&1
sleep 10
$C -f docker/drills/28d-loopback.yml ps

step "SYMPTOM: from the host, on the PUBLISHED port $APP_PORT"
curl -s -m 3 -o /dev/null -w '  HTTP %{http_code}\n' "http://127.0.0.1:$APP_PORT/healthz" </dev/null
echo "  curl exit $? (7 = connection refused, 28 = timed out)"

step "but it works INSIDE the container"
$C -f docker/drills/28d-loopback.yml exec -T app \
  wget -qO- http://127.0.0.1:3000/healthz && echo "  <-- so the app is fine"

step "DIAGNOSIS: what address is it actually listening on?"
$C -f docker/drills/28d-loopback.yml exec -T app netstat -lntp 2>/dev/null \
  || $C -f docker/drills/28d-loopback.yml exec -T app sh -c '
      echo "  netstat missing, decoding /proc/net/tcp by hand:"
      awk "NR>1 {print \$2}" /proc/net/tcp'
echo "  (/proc/net/tcp is little-endian hex: 0100007F = 127.0.0.1, 00000000 = 0.0.0.0;"
echo "   0BB8 = 3000)"

step "the app's own startup log says it too"
$C -f docker/drills/28d-loopback.yml logs app 2>&1 | grep -i listening | tail -2

step "FIX: bind 0.0.0.0 and the same published port answers"
$C down >/dev/null 2>&1
$C up -d app >/dev/null 2>&1
sleep 10
curl -s -m 3 -o /dev/null -w '  HTTP %{http_code}\n' "http://127.0.0.1:$APP_PORT/healthz" </dev/null
$C -f docker/docker-compose.yml exec -T app netstat -lntp 2>/dev/null | grep 3000
$C down >/dev/null 2>&1

echo; echo "############ drills complete ############"
