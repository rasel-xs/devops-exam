#!/usr/bin/env bash
# B3 task 34 -- fix ONE deliberate problem and prove it with numbers.
#
# Chosen: problem 3, the missing index on tags.note_id. Panel D said
# tags_for_note runs at 328 req/s (75x anything else) and panel F said up to
# 358 req/s of those exceed 50ms. Duration x frequency, not duration alone.
#
# Measured at three levels, because a fix that only looks good in one of them
# is not a fix:
#   1. the query plan          (EXPLAIN ANALYZE -- did the planner change?)
#   2. the database            (100 lookups, and the write cost of the index)
#   3. the HTTP endpoint       (what a user actually experiences)
set -u
C="docker compose -f docker/docker-compose.yml"
API=http://127.0.0.1:3120
PSQL="$C exec -T postgres psql -U notes -d notes"
step()   { echo; echo "--- $* ---"; }
banner() { echo; echo "############ $* ############"; echo "EXAM_TOKEN: ${EXAM_TOKEN:-NOT SET} | $(date)"; }

# Time N sequential GETs and report the mean.
time_endpoint() {
  local url=$1 n=${2:-5} total=0 t
  for _ in $(seq 1 "$n"); do
    t=$(curl -s -o /dev/null -w '%{time_total}' -H 'X-Tenant: globex' --max-time 120 "$url" </dev/null)
    total=$(awk -v a="$total" -v b="$t" 'BEGIN{print a+b}')
  done
  awk -v s="$total" -v n="$n" 'BEGIN{printf "  mean %.3f s over %d requests\n", s/n, n}'
}

banner "TASK 34  fix the missing index on tags.note_id"

step "state before: what indexes exist on tags?"
$PSQL -c '\d tags'

step "BEFORE 1/3 -- the query plan"
$PSQL -c 'EXPLAIN (ANALYZE, BUFFERS) SELECT name FROM tags WHERE note_id = 12345;'

step "BEFORE 2/3 -- 100 lookups"
$PSQL -c '\timing on' -c "SELECT sum(c) FROM (SELECT (SELECT count(*) FROM tags WHERE note_id = g) AS c FROM generate_series(1000, 1099) g) x;"

step "BEFORE 3/3 -- HTTP: GET /api/notes?limit=20 (21 queries per request)"
time_endpoint "$API/api/notes?limit=20" 5

step "BEFORE -- write cost: INSERT 10,000 tags"
$PSQL -c '\timing on' -c "INSERT INTO tags (note_id, name) SELECT 1, 'bench-before' FROM generate_series(1,10000);"
$PSQL -c "DELETE FROM tags WHERE name = 'bench-before';" >/dev/null

step "sizes before"
$PSQL -tAc "SELECT 'tags heap: ' || pg_size_pretty(pg_relation_size('tags'));"
$PSQL -tAc "SELECT 'tags total (heap+indexes): ' || pg_size_pretty(pg_total_relation_size('tags'));"


# ─────────────────────────────────────────────────────────────── THE FIX ───
step "THE FIX"
$PSQL -c '\timing on' -c 'CREATE INDEX idx_tags_note_id ON tags (note_id);'
# ANALYZE, not just CREATE INDEX. The planner chooses on statistics; without
# fresh ones it can keep picking the sequential scan it has always picked.
$PSQL -c '\timing on' -c 'ANALYZE tags;'
$PSQL -c '\d tags'


step "AFTER 1/3 -- the query plan"
$PSQL -c 'EXPLAIN (ANALYZE, BUFFERS) SELECT name FROM tags WHERE note_id = 12345;'

step "AFTER 2/3 -- the same 100 lookups"
$PSQL -c '\timing on' -c "SELECT sum(c) FROM (SELECT (SELECT count(*) FROM tags WHERE note_id = g) AS c FROM generate_series(1000, 1099) g) x;"

step "AFTER 3/3 -- HTTP: the same endpoint"
time_endpoint "$API/api/notes?limit=20" 5

step "AFTER -- write cost: the same INSERT, now maintaining a b-tree too"
$PSQL -c '\timing on' -c "INSERT INTO tags (note_id, name) SELECT 1, 'bench-after' FROM generate_series(1,10000);"
$PSQL -c "DELETE FROM tags WHERE name = 'bench-after';" >/dev/null

step "what the fix cost on disk"
$PSQL -tAc "SELECT 'index: ' || pg_size_pretty(pg_relation_size('idx_tags_note_id'));"
$PSQL -tAc "SELECT 'tags heap: ' || pg_size_pretty(pg_relation_size('tags'));"
$PSQL -tAc "SELECT 'tags total: ' || pg_size_pretty(pg_total_relation_size('tags'));"

step "the heavy case: ?limit=2000 used to exceed a 120s timeout"
time_endpoint "$API/api/notes?limit=2000" 1

step "restart the app to drop a deploy annotation on the dashboard"
$C restart app >/dev/null
sleep 12

step "60s of load AFTER the fix, for the before/after panels"
bash app/loadtest.sh "$API" 60 2>&1 | tail -14

echo
echo "############ task 34 complete ############"
echo "To reproduce the BEFORE state:  DROP INDEX idx_tags_note_id;"
