#!/usr/bin/env bash
# B2 task 27 -- volumes, `down` vs `down -v`, and recovery from a backup.
#
# Ground truth for the row counts is psql, not the API: the API could be
# reading a cache or the wrong database, psql cannot.

CD=docker/docker-compose.yml
COMPOSE="docker compose -f $CD"
API=http://127.0.0.1:3120
MARK="TASK27-$(date +%H%M%S)"

section() { printf '\n\n========== %s ==========\n' "$*"; }

count() {
  $COMPOSE exec -T postgres psql -U notes -d notes -tAc \
    'SELECT count(*) FROM notes;' 2>/dev/null | tr -d '[:space:]'
}

vols() {
  echo "  volumes matching abdur-notes:"
  docker volume ls --format '    {{.Name}}' | grep abdur-notes || echo "    (none)"
}

wait_ready() {
  local i code
  for i in $(seq 1 60); do
    code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 2 "$API/readyz" </dev/null 2>/dev/null)
    [ "$code" = "200" ] && { echo "  ready after ${i} tries"; return 0; }
    sleep 1
  done
  echo "  NEVER became ready"; return 1
}

tenants() {
  $COMPOSE exec -T postgres psql -U notes -d notes -tAc \
    'SELECT count(*) FROM tenants;' 2>/dev/null | tr -d '[:space:]'
}

section "SETUP -- fixed stack up, schema applied, DATA SEEDED"
$COMPOSE up -d postgres app
wait_ready
echo "  tenants: $(tenants)   notes: $(count)"
# The first run of this script wrote nothing at all: every POST came back
# `unknown tenant: acme`. resolveTenant looks the slug up in the `tenants`
# table, migrate.js only creates the schema, and the rows come from seed.js --
# which had never been run. A backup of an empty database restoring an empty
# database proves nothing, so seed first.
#
# Seeding happens ONLY here, in setup. Re-seeding after the `down -v` would
# destroy the very thing this task is trying to demonstrate.
if [ "$(tenants)" = "0" ]; then
  echo "--- tenants table is empty, running the seeder (50k notes, 150k tags) ---"
  $COMPOSE exec -T app node db/seed.js
else
  echo "--- already seeded, leaving it alone ---"
fi
echo "  tenants: $(tenants)   notes: $(count)"

section "STEP 1 -- write data through the API"
for n in 1 2 3; do
  curl -s -X POST "$API/api/notes" \
       -H 'Content-Type: application/json' -H 'X-Tenant: acme' \
       -d "{\"title\":\"$MARK-$n\",\"body\":\"written before down -v\",\"tags\":[\"t27\"]}" \
       </dev/null | head -c 120
  echo
done
BEFORE=$(count)
echo "  notes now: $BEFORE"

section "STEP 2 -- docker compose down   (no -v)"
$COMPOSE down
vols
echo "--- up again ---"
$COMPOSE up -d postgres app >/dev/null 2>&1
wait_ready
AFTER_DOWN=$(count)
echo "  notes after plain 'down' + 'up': $AFTER_DOWN   (was $BEFORE)"

section "STEP 3 -- take a backup FIRST"
bash docker/backup-restore.sh backup
LATEST=$(ls -1t backups/notes-*.sql.gz 2>/dev/null | head -1)
echo "  latest backup: $LATEST"

section "STEP 4 -- docker compose down -v   (the destructive one)"
$COMPOSE down -v
vols
echo "--- up again on the volume docker just re-created ---"
$COMPOSE up -d postgres app >/dev/null 2>&1
wait_ready
AFTER_DOWNV=$(count)
echo "  notes after 'down -v' + 'up': $AFTER_DOWNV   (was $BEFORE)"

section "STEP 5 -- restore from the backup"
bash docker/backup-restore.sh restore "$LATEST"
RESTORED=$(count)
echo "  notes after restore: $RESTORED"
echo
echo "--- are my marker rows actually back? ---"
$COMPOSE exec -T postgres psql -U notes -d notes -c \
  "SELECT id, title FROM notes WHERE title LIKE '$MARK%' ORDER BY id;"

section "SUMMARY"
printf '  %-38s %s\n' "notes written"                 "$BEFORE"
printf '  %-38s %s\n' "after 'down' + 'up'"           "$AFTER_DOWN"
printf '  %-38s %s\n' "after 'down -v' + 'up'"        "$AFTER_DOWNV"
printf '  %-38s %s\n' "after restore"                 "$RESTORED"
