#!/usr/bin/env bash
# B4 task 35 -- build and push v1/v2/v3, init the swarm, deploy the stack.
#
# Namespaced for a shared host: stack `abdur_notes` (so services are
# abdur_notes_app / abdur_notes_postgres), published port 3140, overlay
# abdur_notes_notes_net. Note that `docker swarm init` itself is NOT
# namespaceable -- it is daemon-wide state. Never run `docker swarm leave
# --force` here: it would destroy every stack on this host, not just mine.
set -u
REG=${REG:-ghcr.io/rasel-xs}
STACK=abdur_notes
IP=${IP:-169.58.246.108}
step()   { echo; echo "--- $* ---"; }
banner() { echo; echo "############ $* ############"; echo "EXAM_TOKEN: ${EXAM_TOKEN:-NOT SET} | $(date)"; }

banner "TASK 35  deploy the stack"

step "1. build the three images"
# v1 is the image B1-B3 was built and measured against, retagged.
docker tag abdur/notes-api:multi "$REG/notes-api:v1"
# v2: same code, APP_VERSION=v2, so the rolling update in task 37 is visible.
docker build -q -f docker/Dockerfile.v2       -t "$REG/notes-api:v2" . 
# v3: /healthz returns 500. The container RUNS but never turns healthy -- which
# is the failure mode task 38 asks about, and the one a healthcheck is for.
docker build -q -f docker/Dockerfile.v3broken -t "$REG/notes-api:v3" .
docker images | grep "notes-api" | grep -E 'v1|v2|v3'

step "2. push all three to GHCR"
for t in v1 v2 v3; do
  echo "  pushing $REG/notes-api:$t"
  docker push -q "$REG/notes-api:$t" || docker push "$REG/notes-api:$t"
done

step "3. confirm they are really in the registry, not just local"
# Pulling by DIGEST from a fresh manifest read proves the registry has it.
for t in v1 v2 v3; do
  printf '  %-4s %s\n' "$t" "$(docker manifest inspect "$REG/notes-api:$t" >/dev/null 2>&1 && echo 'present in registry' || echo '*** NOT IN REGISTRY ***')"
done

step "4. swarm init"
docker swarm init --advertise-addr "$IP" 2>&1 || echo "  (already a swarm member -- continuing)"

step "5. docker node ls   [TASK 35 DELIVERABLE]"
docker node ls

step "6. deploy the stack"
# --with-registry-auth pushes this login into the service spec so tasks can
# pull the private GHCR image. On one node it appears to work without it,
# because the manager daemon already holds the credentials -- which is exactly
# why it is easy to forget until a second node exists.
REGISTRY="$REG" TAG=v1 docker stack deploy \
  -c docker/stack.yml --with-registry-auth "$STACK"

step "7. wait for convergence"
for i in $(seq 1 30); do
  line=$(docker stack services "$STACK" --format '{{.Name}} {{.Replicas}}' | tr '\n' ' ')
  echo "  $(date +%T)  $line"
  echo "$line" | grep -q '3/3' && echo "$line" | grep -q '1/1' && break
  sleep 5
done

step "8. docker stack services   [TASK 35 DELIVERABLE]"
docker stack services "$STACK"

step "9. where each task actually landed"
docker service ps "${STACK}_app" --format 'table {{.Name}}\t{{.Node}}\t{{.CurrentState}}\t{{.Error}}'

step "10. does it answer?"
sleep 5
curl -s -i -H 'Connection: close' http://127.0.0.1:3140/healthz | head -8

echo; echo "############ task 35 complete ############"
