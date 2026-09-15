#!/usr/bin/env bash
# Scenario C4 -- proofs for tasks 59-62, run ON THE VPS after c4-install.sh.
#
#   curl -fsSL https://raw.githubusercontent.com/rasel-xs/devops-exam/main/scenario-c/c4-demo.sh -o /root/abdur-c4-demo.sh
#   clear; bash /root/abdur-c4-demo.sh 59        # one part per screenshot
#
# Parts: 59  60  61  621  622  623  624   (or: all)
# 623 and 624 flip nginx into the vulnerable state to SHOW the bug, then back;
# both always finish in the safe state (header fixed, metrics blocked).
set -uo pipefail

PART=${1:-all}
BASE=abdur.169.58.246.108.nip.io
PORT=8141
SSLIP=169.58.246.108.sslip.io
CUSTOM=notes.globex-corp.$SSLIP
INSTALL=/root/abdur-c4-install.sh

stamp() { echo; echo "EXAM_TOKEN: $(cat /root/abdur_exam_token.txt 2>/dev/null) | $(date)"; }
step()  { stamp; echo "=== $* ==="; }
want()  { [ "$PART" = all ] || [ "$PART" = "$1" ]; }
# show: prints the command, then the body (first 400 chars) and the status
show()  { echo "\$ curl $*"; curl -sS --max-time 8 -w '\n[HTTP %{http_code}]\n' "$@" | cut -c1-400; echo; }
titles(){ curl -sS --max-time 8 "$@" | grep -oE '"title":"[^"]*"' | head -3 | tr '\n' ' '; echo; }

[ -f "$INSTALL" ] || curl -fsSL https://raw.githubusercontent.com/rasel-xs/devops-exam/main/scenario-c/c4-install.sh -o "$INSTALL"

# -----------------------------------------------------------------------------
if want 59; then
  step "TASK 59 -- wildcard DNS + one regex server block + ONE app instance"
  for h in acme globex; do
    echo "--- $h.$BASE:$PORT/api/notes"
    echo "\$ curl http://$h.$BASE:$PORT/api/notes?limit=3"
    printf '  titles: '; titles "http://$h.$BASE:$PORT/api/notes?limit=3"
    curl -sS -o /dev/null -w '  [HTTP %{http_code}]\n' "http://$h.$BASE:$PORT/api/notes?limit=3"
  done
  echo "--- a tenant that does not exist: clean 404, no crash"
  show "http://doesnotexist.$BASE:$PORT/api/notes"
  echo "--- DNS: every name under the base resolves to this one server"
  for h in acme globex doesnotexist; do printf '  %-40s -> %s\n' "$h.$BASE" "$(getent hosts "$h.$BASE" | awk '{print $1}')"; done
  echo "--- the one app serving all of them"
  echo "\$ docker service ls --filter name=abdur_notes_app"
  docker service ls --filter name=abdur_notes_app
  echo "\$ docker service ps abdur_notes_app --filter desired-state=running"
  docker service ps abdur_notes_app --filter desired-state=running --format 'table {{.Name}}\t{{.Image}}\t{{.Node}}\t{{.CurrentState}}'
  echo "--- the one nginx server block that matches every tenant"
  grep -nE 'listen 8141|server_name' /etc/nginx/sites-available/abdur-c4
fi

# -----------------------------------------------------------------------------
if want 60; then
  NEW=${2:-initech}
  step "TASK 60 -- provision '$NEW', then IMMEDIATELY curl its subdomain"
  echo "before: nginx config last changed $(stat -c '%y' /etc/nginx/sites-available/abdur-c4 | cut -d. -f1)"
  echo
  show -X POST "http://$BASE:$PORT/api/tenants" -H 'Content-Type: application/json' -d "{\"slug\":\"$NEW\",\"name\":\"Initech LLC\"}"
  echo "\$ curl http://$NEW.$BASE:$PORT/api/notes      <- no DNS or nginx change in between"
  printf '  titles: '; titles "http://$NEW.$BASE:$PORT/api/notes"
  curl -sS -o /dev/null -w '  [HTTP %{http_code}]\n' "http://$NEW.$BASE:$PORT/api/notes"
  echo "after:  nginx config last changed $(stat -c '%y' /etc/nginx/sites-available/abdur-c4 | cut -d. -f1)"
  echo
  echo "--- validation: reserved names and a dotted slug are refused"
  for bad in www api admin "acme.evil"; do
    printf '  slug %-10s -> ' "$bad"
    curl -sS -X POST "http://$BASE:$PORT/api/tenants" -H 'Content-Type: application/json' \
      -d "{\"slug\":\"$bad\",\"name\":\"x\"}" -w '  [HTTP %{http_code}]\n'
  done
fi

# -----------------------------------------------------------------------------
if want 61; then
  step "TASK 61 -- custom domain: $CUSTOM -> tenant globex"
  echo "(route: a second real domain, sslip.io, whose names resolve to the IP inside them)"
  printf '  %s -> %s\n' "$CUSTOM" "$(getent hosts "$CUSTOM" | awk '{print $1}')"
  echo
  echo "1. globex claims it (request arrives on globex's own subdomain)"
  show -X POST "http://globex.$BASE:$PORT/api/domains" -H 'Content-Type: application/json' -d "{\"domain\":\"$CUSTOM\"}"
  echo "2. before verification the domain serves nothing"
  show "http://$CUSTOM:$PORT/api/notes"
  echo "3. verify: the app resolves the name and checks it points here"
  show -X POST "http://globex.$BASE:$PORT/api/domains/$CUSTOM/verify"
  echo "4. now the custom domain is globex"
  echo "\$ curl http://$CUSTOM:$PORT/api/notes"
  printf '  titles: '; titles "http://$CUSTOM:$PORT/api/notes"
  curl -sS -o /dev/null -w '  [HTTP %{http_code}]\n' "http://$CUSTOM:$PORT/api/notes"
fi

# -----------------------------------------------------------------------------
if want 621; then
  step "TASK 62.1 -- DNS pointed at us, domain never added or verified"
  show "http://notes.unknowncompany.$SSLIP:$PORT/"
  show "http://notes.unknowncompany.$SSLIP:$PORT/api/notes"
fi

# -----------------------------------------------------------------------------
if want 622; then
  step "TASK 62.2 -- a second tenant claims a domain globex already has"
  show -X POST "http://acme.$BASE:$PORT/api/domains" -H 'Content-Type: application/json' -d "{\"domain\":\"$CUSTOM\"}"
  echo "--- what enforces it: the primary key, in the database"
  PG=$(docker ps --filter name=abdur_notes_postgres --format '{{.ID}}' | head -1)
  docker exec "$PG" psql -U notes -d notes -c '\d tenant_domains'
fi

# -----------------------------------------------------------------------------
if want 623; then
  step "TASK 62.3 -- can a client fake the tenant header?  (1) the BUGGY config"
  bash "$INSTALL" --header buggy --metrics blocked --nginx-only | grep -E 'X-Tenant|reloaded'
  echo "\$ curl -H 'X-Tenant: globex' http://acme.$BASE:$PORT/api/notes"
  printf '  titles: '; titles -H 'X-Tenant: globex' "http://acme.$BASE:$PORT/api/notes"
  echo "  ^ acme's hostname, globex's notes: VULNERABLE"
  step "TASK 62.3 -- (2) FIXED: nginx always overwrites X-Tenant from the hostname"
  bash "$INSTALL" --header fixed --metrics blocked --nginx-only | grep -E 'X-Tenant|reloaded'
  echo "\$ curl -H 'X-Tenant: globex' http://acme.$BASE:$PORT/api/notes"
  printf '  titles: '; titles -H 'X-Tenant: globex' "http://acme.$BASE:$PORT/api/notes"
  echo "  ^ the fake header is replaced: acme's notes"
fi

# -----------------------------------------------------------------------------
if want 624; then
  step "TASK 62.4 -- one more isolation bug: /metrics on a tenant hostname  (1) BUG"
  bash "$INSTALL" --header fixed --metrics open --nginx-only | grep -E 'metrics|reloaded'
  curl -sS -o /dev/null "http://globex.$BASE:$PORT/api/notes?limit=1"     # globex does something
  echo "\$ curl http://acme.$BASE:$PORT/metrics | grep 'tenant=\"globex\"'"
  curl -sS "http://acme.$BASE:$PORT/metrics" | grep 'tenant="globex"' | head -4
  echo "  ^ acme's hostname shows globex's traffic, routes and status codes"
  step "TASK 62.4 -- (2) FIXED"
  bash "$INSTALL" --header fixed --metrics blocked --nginx-only | grep -E 'metrics|reloaded'
  show "http://acme.$BASE:$PORT/metrics"
  echo "--- Prometheus still scrapes the app directly, bypassing tenant hostnames:"
  echo "\$ curl http://127.0.0.1:3140/metrics | grep -c http_requests_total"
  curl -sS http://127.0.0.1:3140/metrics | grep -c http_requests_total
fi

stamp
echo "=== done ==="
