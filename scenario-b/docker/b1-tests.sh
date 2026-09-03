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

# Build first. My first run tested the image left over from an earlier build,
# so task 21b reported npm as present when the current Dockerfile had already
# removed it. Tests must run against what the Dockerfile produces NOW.
hr "SETUP: build both images from the current Dockerfiles"
docker build -q -f docker/Dockerfile.naive -t "$NAIVE" app/ >/dev/null
docker build -q -f docker/Dockerfile       -t "$IMG"   app/ >/dev/null
echo "  built $IMG and $NAIVE"

# ------------------------------------------------------------- task 21 ------
hr "TASK 21a: the final image does NOT run as root"
echo -n '$ docker run --rm '"$IMG"' whoami  -> '
docker run --rm "$IMG" whoami
echo -n '$ docker run --rm '"$IMG"' id      -> '
docker run --rm "$IMG" id

hr "TASK 21b: no build tools or dev dependencies survived"
for tool in gcc g++ make python3 npm npx yarn git curl vim apk; do
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
echo
echo "  NOTE: 'docker images' and 'image inspect .Size' disagree on this box."
echo "  docker images reports the uncompressed on-disk size of every platform"
echo "  in the manifest list; inspect .Size reports the packed size of one"
echo "  platform. Both are printed below -- the ratio is what matters and the"
echo "  two agree on it."
awk -v n="$NB" -v m="$MB" 'BEGIN {
  printf "  naive       : %.0f MB\n", n/1048576
  printf "  multi-stage : %.0f MB\n", m/1048576
  printf "  reduction   : %.1f%%  (brief requires >= 60%%)\n", (1 - m/n) * 100
}'

# ------------------------------------------------------------- task 23 ------
hr "TASK 23a: cold build (--no-cache)"
# --progress=plain prints every step with its CACHED marker. The default
# "auto" progress collapses finished steps, which is why my first attempt
# could not show which layers rebuilt.
time docker build --no-cache --progress=plain -f docker/Dockerfile -t "$IMG" app/ 2>&1 \
  | grep -E '^#[0-9]+ \[' | sort -u | head -20

hr "TASK 23b: rebuild with NO source change -- every layer should be CACHED"
time docker build --progress=plain -f docker/Dockerfile -t "$IMG" app/ 2>&1 \
  | grep -E 'CACHED|^#[0-9]+ \[' | sort -u | head -20

hr "TASK 23c: change ONE line of source, then rebuild"
echo "// cache-test comment $(date +%s)" >> app/src/server.js
echo "appended a comment to app/src/server.js"
echo
time docker build --progress=plain -f docker/Dockerfile -t "$IMG" app/ 2>&1 \
  | grep -E 'CACHED|^#[0-9]+ \[' | sort -u | head -20
sed -i '/^\/\/ cache-test comment/d' app/src/server.js
echo "(comment removed again)"
echo
echo "READ IT LIKE THIS: the npm ci layer stays CACHED because package.json did"
echo "not change, and the cache miss starts at COPY src -- every layer from"
echo "there down is rebuilt, because Docker's cache is a chain."

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
echo "--- unpack EVERY layer and search inside it ---"
# Two things the first version of this test got wrong:
#   1. `docker save` on Docker 25+ writes OCI blobs (blobs/sha256/<digest>),
#      not per-layer *.tar files, so counting *.tar counted nothing.
#   2. `grep -I` SKIPS binary files, and layer blobs are gzipped tarballs --
#      so the search never looked inside them at all.
# Each blob is therefore extracted first, and the search runs on real files.
scan_image() {
  local image=$1 tmp
  tmp=$(mktemp -d)
  docker save "$image" -o "$tmp/img.tar"
  mkdir -p "$tmp/x" "$tmp/layers"
  tar -xf "$tmp/img.tar" -C "$tmp/x"

  local n=0
  for blob in $(find "$tmp/x" -type f); do
    # A layer blob is a tar (often gzipped). Anything that untars is a layer.
    if tar -tf "$blob" >/dev/null 2>&1; then
      n=$((n + 1))
      mkdir -p "$tmp/layers/l$n"
      tar -xf "$blob" -C "$tmp/layers/l$n" 2>/dev/null || true
    fi
  done
  echo "  layers extracted : $n"

  # Print the MATCHING LINE for each hit, not just the filename. Without it a
  # hit cannot be triaged, and this scan does produce false positives: npm and
  # yarn ship documentation containing example keys.
  local hits
  hits=$(grep -ral -E 'hunter2|LEAKED-MARKER|BEGIN [A-Z ]*PRIVATE KEY|AWS_SECRET_ACCESS_KEY' \
         "$tmp/layers" 2>/dev/null | head -8)
  if [ -n "$hits" ]; then
    echo "  MATCHES (each needs triage -- a match is not automatically a leak):"
    while IFS= read -r f; do
      printf '    %s\n' "${f#$tmp/layers/}"
      grep -ahm1 -E 'hunter2|LEAKED-MARKER|BEGIN [A-Z ]*PRIVATE KEY|AWS_SECRET_ACCESS_KEY' \
        "$f" 2>/dev/null | cut -c1-110 | sed 's/^/        > /'
    done <<< "$hits"
  else
    echo "  no matches in any extracted layer"
  fi
  rm -rf "$tmp"
}

echo
echo ">>> NEGATIVE CONTROL: an image that deliberately leaks."
echo "    Dockerfile.leaky writes a secret, then deletes it in a later layer --"
echo "    exactly the trap in the brief. If the scan cannot find it HERE, the"
echo "    scan is broken and 'nothing found' in my real image means nothing."
docker build -q -f docker/Dockerfile.leaky -t abdur/notes-api:leaky app/ >/dev/null
echo "    (the file is NOT in the running container:)"
docker run --rm abdur/notes-api:leaky sh -c 'ls -la /app/.env 2>&1 || echo "      no /app/.env -- looks clean"'
echo "    (but the bytes are still in an earlier layer:)"
scan_image abdur/notes-api:leaky

echo
echo ">>> THE REAL IMAGE, scanned exactly the same way:"
scan_image "$IMG"
docker rmi abdur/notes-api:leaky >/dev/null 2>&1

echo
echo "--- and .dockerignore is why: the file never enters the build context ---"
grep -nE '^\.env' app/.dockerignore

hr "END"
