#!/usr/bin/env bash
# B3 task 34, follow-up: what does the index ACTUALLY cost on writes?
#
# The first attempt measured 731ms without the index and 465ms with it, i.e.
# the index apparently made INSERTs faster. That is not possible; the
# measurement was unfair. The "before" run extended the heap into fresh pages
# with a cold cache; then 10,000 rows were DELETEd, leaving free space that the
# "after" run reused. Two different amounts of work, reported as one
# comparison.
#
# Controlled version:
#   * three runs per condition, not one
#   * VACUUM between runs, so every run starts from the same free-space state
#   * conditions ALTERNATED (with, without, with, without, ...) so that any
#     drift in cache warmth or noise from other tenants on this shared VPS
#     affects both sides equally instead of only the later one
set -u
C="docker compose -f docker/docker-compose.yml"
PSQL="$C exec -T postgres psql -U notes -d notes -tA"
banner() { echo; echo "############ $* ############"; echo "EXAM_TOKEN: ${EXAM_TOKEN:-NOT SET} | $(date)"; }

bench() {                       # bench <label>
  local label=$1 ms
  $PSQL -c 'VACUUM (ANALYZE) tags;' >/dev/null 2>&1
  ms=$($PSQL -c "\\timing on" \
             -c "INSERT INTO tags (note_id, name) SELECT 1, 'wc-bench' FROM generate_series(1,10000);" 2>&1 \
       | grep -oE 'Time: [0-9.]+' | grep -oE '[0-9.]+')
  $PSQL -c "DELETE FROM tags WHERE name = 'wc-bench';" >/dev/null 2>&1
  printf '  %-14s %10s ms\n' "$label" "$ms"
}

banner "TASK 34 follow-up  the real write cost of idx_tags_note_id"

echo "  alternating conditions, VACUUM before each run"
echo
for round in 1 2 3; do
  echo "round $round"
  $PSQL -c 'CREATE INDEX IF NOT EXISTS idx_tags_note_id ON tags (note_id);' >/dev/null 2>&1
  bench "with index"
  $PSQL -c 'DROP INDEX IF EXISTS idx_tags_note_id;' >/dev/null 2>&1
  bench "without index"
done

echo
echo "restoring the index (it is the task 34 fix)"
$PSQL -c 'CREATE INDEX IF NOT EXISTS idx_tags_note_id ON tags (note_id);' >/dev/null 2>&1
$PSQL -c 'ANALYZE tags;' >/dev/null 2>&1
$C exec -T postgres psql -U notes -d notes -c '\d tags' | grep -A3 Indexes

echo
echo "and the read side, one more time, to confirm the index is back:"
$C exec -T postgres psql -U notes -d notes \
  -c 'EXPLAIN (ANALYZE, BUFFERS) SELECT name FROM tags WHERE note_id = 12345;' \
  | grep -E 'Scan|Execution Time|Buffers: shared'
