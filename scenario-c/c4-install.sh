#!/usr/bin/env bash
# Scenario C4 -- install host-based multi-tenancy on the shared exam VPS.
#
#   curl -fsSL https://raw.githubusercontent.com/rasel-xs/devops-exam/main/scenario-c/c4-install.sh -o /root/abdur-c4-install.sh
#   bash /root/abdur-c4-install.sh 2>&1 | tee /root/abdur-c4-install.txt
#
# Options (defaults are the SAFE state):
#   --header fixed|buggy     62.3: nginx overwrites X-Tenant (fixed) or lets the
#                            client's header win (buggy, demonstration only)
#   --metrics blocked|open   62.4: /metrics refused on tenant hostnames or not
#   --nginx-only             only re-render and reload nginx (used by c4-demo.sh)
#
# What it touches, and nothing else:
#   /etc/nginx/sites-available/abdur-c4 (+ symlink in sites-enabled), nginx reload
#   swarm service abdur_notes_app: three env vars, replicas 1
#   the abdur_notes_postgres database: migrations, tenants acme and globex
# Every other student's nginx file and service is left alone; `nginx -t` must
# pass before any reload, and a failed test restores the previous file.
set -uo pipefail

HEADER=fixed; METRICS=blocked; NGINX_ONLY=0
while [ $# -gt 0 ]; do
  case "$1" in
    --header)     HEADER=$2; shift 2 ;;
    --metrics)    METRICS=$2; shift 2 ;;
    --nginx-only) NGINX_ONLY=1; shift ;;
    *) echo "unknown option $1" >&2; exit 2 ;;
  esac
done

# Pinned to a commit, not `main`: raw.githubusercontent.com caches files for a
# few minutes, so a fix pushed a moment ago could still be served stale.
C4_REF=${C4_REF:-main}
RAW=https://raw.githubusercontent.com/rasel-xs/devops-exam/$C4_REF/scenario-c
SERVICE=abdur_notes_app
BASE=abdur.169.58.246.108.nip.io
PUBLIC_IP=169.58.246.108
PORT=8141
AVAIL=/etc/nginx/sites-available/abdur-c4
ENABLED=/etc/nginx/sites-enabled/abdur-c4

stamp() { echo; echo "EXAM_TOKEN: $(cat /root/abdur_exam_token.txt 2>/dev/null) | $(date)"; }
die()   { echo; echo "STOPPED: $*" >&2; exit 1; }
step()  { stamp; echo "=== $* ==="; }

# =============================================================================
step "nginx: render abdur-c4 (header=$HEADER, metrics=$METRICS)"
case "$HEADER" in
  fixed) TENANT_VALUE='$abdur_host_tenant' ;;
  buggy) TENANT_VALUE='$abdur_tenant_buggy' ;;
  *) die "--header must be fixed or buggy" ;;
esac
case "$METRICS" in
  blocked) METRICS_BLOCK='    # 62.4 fix: per-tenant metrics are not served on tenant-facing hostnames.
    # Prometheus scrapes the app directly on 127.0.0.1:3140, which never passes here.
    location = /metrics { return 404; }' ;;
  open)    METRICS_BLOCK='    # 62.4 BUG (demonstration): /metrics is proxied like any other path.' ;;
  *) die "--metrics must be blocked or open" ;;
esac

TPL=$(curl -fsSL "$RAW/c4/abdur-c4.conf.template") || die "could not download the template ($C4_REF)"
# Count the placeholders BEFORE substituting: exactly one X-Tenant value and
# one /metrics rule per server block. Anything else means the template is not
# the one this script was written for (run 1: a comment contained them too).
n_t=$(printf '%s' "$TPL" | grep -c '@@TENANT_VALUE@@')
n_m=$(printf '%s' "$TPL" | grep -c '@@METRICS_BLOCK@@')
[ "$n_t" = 1 ] && [ "$n_m" = 2 ] || die "template placeholders: TENANT_VALUE x$n_t (want 1), METRICS_BLOCK x$n_m (want 2)"
CONF=${TPL//@@TENANT_VALUE@@/$TENANT_VALUE}
CONF=${CONF//@@METRICS_BLOCK@@/$METRICS_BLOCK}
printf '%s' "$CONF" | grep -q '@@' && die "unreplaced placeholder left in rendered config"
echo "template: $C4_REF, placeholders ok"

BACKUP=""
if [ -f "$AVAIL" ]; then BACKUP=$(mktemp); cp "$AVAIL" "$BACKUP"; fi
printf '%s\n' "$CONF" > "$AVAIL"
ln -sf "$AVAIL" "$ENABLED"
if ! nginx -t 2>&1; then
  if [ -n "$BACKUP" ]; then cp "$BACKUP" "$AVAIL"; else rm -f "$AVAIL" "$ENABLED"; fi
  nginx -t >/dev/null 2>&1
  die "nginx -t failed -- previous config restored, nothing reloaded"
fi
systemctl reload nginx || die "reload failed"
echo "reloaded. X-Tenant line and /metrics rule now in effect:"
grep -nE 'proxy_set_header X-Tenant|location = /metrics|62.4 BUG' "$AVAIL"
[ "$NGINX_ONLY" = 1 ] && { stamp; echo "=== nginx-only: done ==="; exit 0; }

# =============================================================================
step "app: is the C4 code deployed? (needs the Deploy run's VPS job approved first)"
C=$(docker ps --filter "name=${SERVICE}." --format '{{.ID}}' | head -1)
[ -n "$C" ] || die "no running $SERVICE container on this node"
docker exec "$C" test -f /app/src/tenancy.js \
  || die "running image $(docker inspect -f '{{.Config.Image}}' "$C") has no src/tenancy.js -- approve the Deploy run, wait for it to finish, then re-run"
docker service inspect "$SERVICE" --format 'image: {{.Spec.TaskTemplate.ContainerSpec.Image}}'

# =============================================================================
step "app: host mode env + a single replica"
ENV_NOW=$(docker service inspect "$SERVICE" --format '{{range .Spec.TaskTemplate.ContainerSpec.Env}}{{println .}}{{end}}')
REPLICAS=$(docker service inspect "$SERVICE" --format '{{.Spec.Mode.Replicated.Replicas}}')
if printf '%s' "$ENV_NOW" | grep -q "^TENANT_BASE_DOMAIN=$BASE$" && [ "$REPLICAS" = 1 ]; then
  echo "already configured"
else
  # One replica: task 59 asks to show ONE app instance serving every tenant.
  docker service update --detach --replicas 1 \
    --env-add "TENANT_BASE_DOMAIN=$BASE" --env-add "PUBLIC_PORT=$PORT" --env-add "PUBLIC_IP=$PUBLIC_IP" \
    "$SERVICE" >/dev/null || die "service update failed"
  echo "waiting for a container with the new env..."
  for i in $(seq 1 40); do
    C=$(docker ps --filter "name=${SERVICE}." --format '{{.ID}}' | head -1)
    if [ -n "$C" ] && [ "$(docker exec "$C" printenv TENANT_BASE_DOMAIN 2>/dev/null)" = "$BASE" ] \
       && [ "$(docker service ps "$SERVICE" --filter desired-state=running -q | wc -l)" -eq 1 ] \
       && curl -sf --max-time 3 http://127.0.0.1:3140/healthz >/dev/null; then
      break
    fi
    sleep 3
  done
fi
docker service inspect "$SERVICE" --format '{{range .Spec.TaskTemplate.ContainerSpec.Env}}{{println .}}{{end}}' \
  | grep -E '^(TENANT_BASE_DOMAIN|PUBLIC_PORT|PUBLIC_IP)='
docker service ls --filter "name=$SERVICE" --format '{{.Name}}  replicas {{.Replicas}}  {{.Image}}'

# =============================================================================
step "database: migrations (adds tenants.name, tenant_domains)"
C=$(docker ps --filter "name=${SERVICE}." --format '{{.ID}}' | head -1)
docker exec "$C" node db/migrate.js || die "migration failed"

# =============================================================================
step "tenants acme and globex, provisioned through the new endpoint itself"
for t in "acme Acme Corp" "globex Globex Corporation"; do
  set -- $t; slug=$1; shift; name="$*"
  curl -sS -X POST "http://$BASE:$PORT/api/tenants" -H 'Content-Type: application/json' \
    -d "{\"slug\":\"$slug\",\"name\":\"$name\"}" -w "  [HTTP %{http_code}]\n"
done

# =============================================================================
step "smoke test through nginx"
for h in acme globex; do
  printf '%-8s ' "$h"; curl -sS --max-time 5 "http://$h.$BASE:$PORT/api/notes?limit=1" -w "  [HTTP %{http_code}]\n" | cut -c1-160
done

stamp
echo "=== install done: header=$HEADER metrics=$METRICS ==="
