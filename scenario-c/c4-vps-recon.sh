#!/usr/bin/env bash
# Scenario C4 -- step 0: look at the shared VPS before changing anything.
# READ-ONLY. It starts, stops, edits and reloads nothing.
#
#   curl -fsSL https://raw.githubusercontent.com/rasel-xs/devops-exam/main/scenario-c/c4-vps-recon.sh -o /root/abdur-c4-recon.sh
#   bash /root/abdur-c4-recon.sh 2>&1 | tee /root/abdur-c4-recon.txt
#
# Anything that looks like a password is masked before it is printed, so the
# output is safe to paste into chat.
set -uo pipefail
mask() { sed -E 's#(postgres(ql)?://[^:/@]+:)[^@]+@#\1****@#g; s#((PASS(WORD)?|SECRET|TOKEN)[A-Z_]*=)[^ ]+#\1****#Ig'; }
hr()   { echo; echo "=== $* ==="; }

echo "EXAM_TOKEN: $(cat /root/abdur_exam_token.txt 2>/dev/null) | $(date)"

hr "1. my swarm services (abdur_*)"
docker service ls --format '{{.Name}}\t{{.Image}}\t{{.Replicas}}\t{{.Ports}}' | grep -i abdur

hr "2. the app service: image, published port, env NAMES (values masked)"
docker service inspect abdur_notes_app --format '{{.Spec.TaskTemplate.ContainerSpec.Image}}' 2>&1
docker service inspect abdur_notes_app --format '{{range .Endpoint.Ports}}{{.PublishedPort}}->{{.TargetPort}}/{{.Protocol}} {{end}}' 2>&1
docker service inspect abdur_notes_app --format '{{range .Spec.TaskTemplate.ContainerSpec.Env}}{{println .}}{{end}}' 2>&1 | mask
echo "--- answers on 3140?"; curl -sS --max-time 5 http://127.0.0.1:3140/healthz; echo

hr "3. the database the app uses: service and tenants (read-only query)"
docker service ls --format '{{.Name}}' | grep -iE 'abdur.*(db|postgres|pg)'
PG=$(docker ps --format '{{.ID}} {{.Names}} {{.Image}}' | grep -i abdur | grep -iE 'postgres|db' | head -1 | cut -d' ' -f1)
echo "postgres container: ${PG:-not found on this node}"
if [ -n "${PG:-}" ]; then
  docker exec "$PG" sh -c 'psql -U "${POSTGRES_USER:-notes}" -d "${POSTGRES_DB:-notes}" -Atc "SELECT id, slug FROM tenants ORDER BY id" ' 2>&1 | head -20
  docker exec "$PG" sh -c 'psql -U "${POSTGRES_USER:-notes}" -d "${POSTGRES_DB:-notes}" -Atc "SELECT count(*) AS notes FROM notes" ' 2>&1
  docker exec "$PG" sh -c 'psql -U "${POSTGRES_USER:-notes}" -d "${POSTGRES_DB:-notes}" -Atc "\dt" ' 2>&1
fi

hr "4. nginx: version, what it includes, who listens where"
nginx -v 2>&1
nginx -T 2>/dev/null | grep -E '^\s*include\s' | sort -u
nginx -T 2>/dev/null | grep -nE '^# configuration file|^\s*listen|^\s*server_name' | head -60
echo "--- is 8141 free?"; ss -ltnp 'sport = :8141' | tail -n +2 | grep . || echo "8141 is free"
echo "--- my existing server block (Scenario A)"; sed -n '1,25p' /etc/nginx/sites-available/abdur-myapp 2>&1

hr "5. firewall"
ufw status 2>&1 | head -15

hr "6. do the wildcard DNS names resolve to this VPS?"
for h in acme.abdur.169.58.246.108.nip.io globex.abdur.169.58.246.108.nip.io doesnotexist.abdur.169.58.246.108.nip.io notes.theircompany.169.58.246.108.sslip.io; do
  printf '%-48s -> %s\n' "$h" "$(getent hosts "$h" | awk '{print $1}' | head -1)"
done

echo; echo "EXAM_TOKEN: $(cat /root/abdur_exam_token.txt 2>/dev/null) | $(date)"
echo "=== recon done (nothing was changed) ==="
