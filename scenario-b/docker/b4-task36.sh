#!/usr/bin/env bash
# B4 task 36 -- scale to 5 and prove all five actually serve traffic.
#
# The brief hints that keep-alive can pin every request to one backend. Rather
# than assume it, this runs BOTH ways and compares -- because the answer
# depends on how the requests are issued, and getting it wrong in either
# direction leads to a wrong conclusion about whether scaling works.
set -u
STACK=abdur_notes
SVC=${STACK}_app
URL=http://127.0.0.1:3140/healthz
step()   { echo; echo "--- $* ---"; }
banner() { echo; echo "############ $* ############"; echo "EXAM_TOKEN: ${EXAM_TOKEN:-NOT SET} | $(date)"; }

banner "TASK 36  scale to 5"

step "before"
docker service ls --filter name=$SVC --format 'table {{.Name}}\t{{.Replicas}}\t{{.Image}}'

step "scale"
docker service scale ${SVC}=5

step "wait for 5/5"
for i in $(seq 1 30); do
  r=$(docker service ls --filter name=$SVC --format '{{.Replicas}}')
  echo "  $(date +%T)  $r"
  [ "$r" = "5/5" ] && break
  sleep 3
done

step "docker service ps   [TASK 36 DELIVERABLE]"
docker service ps $SVC --format 'table {{.Name}}\t{{.Node}}\t{{.CurrentState}}\t{{.Error}}'

step "the five container ids swarm thinks are running"
docker ps --filter "name=${SVC}." --format '  {{.ID}}  {{.Names}}' | sort

step "A. 50 requests, each its own connection (Connection: close)"
for i in $(seq 1 50); do
  curl -s -o /dev/null -D - -H "Connection: close" --max-time 5 "$URL" </dev/null \
    | grep -i '^X-Served-By'
done | sort | uniq -c | sort -rn

step "B. 50 requests down ONE keep-alive connection"
# A single curl process given the same URL 50 times reuses the connection. The
# routing mesh load balances per CONNECTION, not per request, so everything
# after the first request lands on whichever task took the first one.
urls=$(for i in $(seq 1 50); do printf '%s ' "$URL"; done)
# shellcheck disable=SC2086
curl -s -o /dev/null -D - --max-time 20 $urls </dev/null \
  | grep -i '^X-Served-By' | sort | uniq -c | sort -rn

step "C. and 50 separate curl processes WITHOUT Connection: close"
# Each curl is a new process, so it opens a new socket anyway and the header
# makes no difference. This is the control that says WHICH factor mattered:
# the header, or the process boundary.
for i in $(seq 1 50); do
  curl -s -o /dev/null -D - --max-time 5 "$URL" </dev/null | grep -i '^X-Served-By'
done | sort | uniq -c | sort -rn

step "how the mesh actually balances -- ipvs table for the published port"
docker service inspect $SVC --format 'VirtualIPs: {{json .Endpoint.VirtualIPs}}'
docker service inspect $SVC --format 'Mode: {{json .Spec.EndpointSpec}}'

echo; echo "############ task 36 complete ############"
