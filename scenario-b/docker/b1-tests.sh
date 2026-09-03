#!/usr/bin/env bash
# B1 tasks 21-25 -- image, size, layer cache, biggest layer, no secrets.
#
#   cd /root/abdur-exam/scenario-b
#   script -q -c 'bash docker/b1-tests.sh' evidence/b1-session.txt
set -u
IMG=abdur/notes-api:multi
NAIVE=abdur/notes-api:naive
CTR=abdur-hc          # 'hc' alone is another student's container on this box

hr() { printf '\n============ %s ============\n' "$*"; }
echo "EXAM_TOKEN: ${EXAM_TOKEN:-NOT SET}"
echo "date      : $(date)"

# ------------------------------------------------------------- task 21 ------
hr "TASK 21a: the final image does NOT run as root"
echo -n '$ docker run --rm '"$IMG"' whoami  -> '
docker run --rm "$IMG" whoami
echo -n '$ docker run --rm '"$IMG"' id      -> '
docker run --rm "$IMG" id

hr "TASK 21b: no build tools or dev dependencies survived"
for tool in gcc g++ make python3 npm git curl vim; do
  if docker run --rm --entrypoint sh "$IMG" -c "command -v $tool" >/dev/null 2>&1; then
    echo "  PRESENT (bad): $tool"
  else
    echo "  absent  (good): $tool"
  fi
done
echo
echo "  for contrast, the naive image:"
for tool in gcc make python3 git; do
  if docker run --rm --entrypoint sh "$NAIVE" -c "command -v $tool" >/dev/null 2>&1; then
    echo "    PRESENT: $tool"
  fi
done

hr "TASK 21c: the HEALTHCHECK actually works"
docker rm -f "$CTR" >/dev/null 2>&1
# No database is attached on purpose: /healthz is liveness only and must pass
# without one. If it needed the DB, a database blip would make the orchestrator
# kill every healthy app container as well.
docker run -d --name "$CTR" "$IMG" >/dev/null
echo "waiting for the healthcheck to report..."
for i in $(seq 1 30); do
  st=$(docker inspect --format='{{.State.Health.Status}}' "$CTR" 2>/dev/null || echo starting)
  [ "$st" = healthy ] && { echo "  healthy after ${i}s"; break; }
  sleep 1
done
docker ps --filter "name=$CTR" --format 'table {{.Names}}\t{{.Status}}'
echo
docker inspect --format='{{json .State.Health}}' "$CTR" | jq . 2>/dev/null \
  || docker inspect --format='{{json .State.Health}}' "$CTR"
docker rm -f "$CTR" >/dev/null

# ------------------------------------------------------------- task 22 ------
hr "TASK 22: size comparison"
docker images --format 'table {{.Repository}}:{{.Tag}}\t{{.Size}}' | grep -E "REPOSITORY|abdur/notes-api"
NB=$(docker image inspect "$NAIVE" --format '{{.Size}}')
MB=$(docker image inspect "$IMG"   --format '{{.Size}}')
awk -v n="$NB" -v m="$MB" 'BEGIN {
  printf "  naive       : %.0f MB\n", n/1048576
  printf "  multi-stage : %.0f MB\n", m/1048576
  printf "  reduction   : %.1f%%  (brief requires >= 60%%)\n", (1 - m/n) * 100
}'

# ------------------------------------------------------------- task 23 ------
hr "TASK 23a: cold build (--no-cache)"
time docker build --no-cache -f docker/Dockerfile -t "$IMG" app/ 2>&1 | tail -5

hr "TASK 23b: rebuild with NO changes -- everything should be CACHED"
time docker build -f docker/Dockerfile -t "$IMG" app/ 2>&1 | grep -E "CACHED|=> \[|DONE" | head -20

hr "TASK 23c: change one line of source, then rebuild"
echo "// cache-test comment $(date +%s)" >> app/src/server.js
echo "appended a comment to app/src/server.js"
time docker build -f docker/Dockerfile -t "$IMG" app/ 2>&1 | grep -E "CACHED|=> \[" | head -20
# put the source back
sed -i '/^\/\/ cache-test comment/d' app/src/server.js
echo "(comment removed again)"

# ------------------------------------------------------------- task 24 ------
hr "TASK 24: which layer is biggest"
docker history "$IMG"
echo
echo "--- sorted by size, with the command that created each ---"
docker history --no-trunc --format "{{.Size}}\t{{.CreatedBy}}" "$IMG" \
  | sort -h -r | head -6 | cut -c1-160

# ------------------------------------------------------------- task 25 ------
hr "TASK 25: prove there are no secrets in the image"
echo "--- is a .env present in the running filesystem? ---"
docker run --rm --entrypoint sh "$IMG" -c 'ls -la /app/.env 2>&1 || echo "  no /app/.env"'

echo
echo "--- does any ENV or layer command mention a secret? ---"
docker image inspect "$IMG" --format '{{json .Config.Env}}'
docker history --no-trunc "$IMG" | grep -iE 'password|secret|api_key|token' \
  || echo "  nothing in the layer commands"

echo
echo "--- unpack EVERY layer and search the raw bytes ---"
TMP=$(mktemp -d)
docker save "$IMG" -o "$TMP/img.tar"
tar -xf "$TMP/img.tar" -C "$TMP"
echo "  layers extracted: $(find "$TMP" -name '*.tar' | wc -l)"
grep -rIl -iE 'hunter2|BEGIN [A-Z ]*PRIVATE KEY|AWS_SECRET_ACCESS_KEY' "$TMP" 2>/dev/null \
  && echo "  ^^ SECRET FOUND" \
  || echo "  no secrets found in any layer"
rm -rf "$TMP"

echo
echo "--- and .dockerignore is why: the file never enters the build context ---"
grep -nE '^\.env' app/.dockerignore

hr "END"
