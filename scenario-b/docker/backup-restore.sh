#!/usr/bin/env bash
# B2 task 27 part 4 -- the backup that would have saved you from `down -v`.
#
#   bash docker/backup-restore.sh backup           # dump to ./backups/
#   bash docker/backup-restore.sh restore FILE     # load it back
#
# Two different things are worth backing up and they are NOT equivalent:
#
#   * a LOGICAL dump (pg_dump): portable across Postgres versions and
#     architectures, restorable into a different server, small. This is what
#     you want. It is what this script does.
#   * a VOLUME tarball (tar of /var/lib/postgresql/data): a physical copy. It
#     only restores into the same major version, and it is only consistent if
#     Postgres is stopped or you use pg_basebackup. Included below as a second
#     function because people reach for it first and should know the caveat.
set -euo pipefail

COMPOSE="docker compose -f $(dirname "$0")/docker-compose.yml"
OUT_DIR="$(dirname "$0")/../backups"
mkdir -p "$OUT_DIR"

backup() {
  local f="$OUT_DIR/notes-$(date +%Y%m%d-%H%M%S).sql.gz"
  # --clean --if-exists so the restore is idempotent instead of colliding with
  # existing tables.
  $COMPOSE exec -T postgres pg_dump -U notes -d notes --clean --if-exists \
    | gzip > "$f"
  echo "wrote $f ($(du -h "$f" | cut -f1))"
  ls -la "$OUT_DIR"
}

restore() {
  local f=${1:?usage: restore <file.sql.gz>}
  gunzip -c "$f" | $COMPOSE exec -T postgres psql -U notes -d notes -v ON_ERROR_STOP=1
  echo "restored from $f"
  $COMPOSE exec -T postgres psql -U notes -d notes \
    -c 'SELECT count(*) AS notes FROM notes;' \
    -c 'SELECT count(*) AS tags FROM tags;'
}

# The physical alternative, for reference. Postgres must be STOPPED first or
# the tarball is a torn copy that may not start.
#
# The volume name is DERIVED, not hardcoded. Compose prefixes volume names with
# the project name, so the volume declared as `pgdata` is really
# `abdur-notes_pgdata`. An earlier version of this script had `docker_pgdata`
# hardcoded from a different project and would have silently tarred nothing.
backup_volume() {
  local cid vol
  cid=$($COMPOSE ps -q postgres)
  vol=$(docker inspect -f '{{range .Mounts}}{{if eq .Destination "/var/lib/postgresql/data"}}{{.Name}}{{end}}{{end}}' "$cid")
  [ -n "$vol" ] || { echo "could not resolve the pgdata volume" >&2; return 1; }
  echo "volume = $vol"
  $COMPOSE stop postgres
  docker run --rm -v "$vol":/data -v "$(cd "$OUT_DIR" && pwd)":/backup alpine \
    tar czf "/backup/pgdata-$(date +%Y%m%d-%H%M%S).tar.gz" -C /data .
  $COMPOSE start postgres
}

case "${1:-}" in
  backup)        backup ;;
  restore)       restore "${2:-}" ;;
  backup-volume) backup_volume ;;
  *) echo "usage: $0 {backup|restore <file>|backup-volume}"; exit 2 ;;
esac
