#!/usr/bin/env bash
# healthcheck.sh -- check the services listed in a config file and report.
#
#   ./healthcheck.sh [path/to/checks.conf]      (default: ./checks.conf)
#
# Exit codes:
#   0  everything healthy (a disk warning alone is still 0 -- it is a warning)
#   1  at least one service failed, or a config line was malformed
#   2  the config file is missing or unreadable
#
# Only one copy runs at a time. If cron starts a second while the first is still
# going, the second exits 0 quietly -- a monitoring script that piles up on a
# slow host is how you turn a slow host into a dead one.

set -uo pipefail          # NOT -e: a failing check is data, not a crash

CONFIG="${1:-./checks.conf}"
LOGFILE="${HEALTHCHECK_LOG:-/var/log/healthcheck.log}"
LOCKFILE="${HEALTHCHECK_LOCK:-/var/lock/healthcheck.lock}"
CURL_TIMEOUT=3
DISK_THRESHOLD=80
HOSTNAME_S=$(hostname -s 2>/dev/null || hostname)

# ---------------------------------------------------------------- colours ---
# Only colour a real terminal. Piping to a file or to logger must stay clean.
if [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; then
  RED=$'\033[0;31m'; GREEN=$'\033[0;32m'; YELLOW=$'\033[0;33m'
  BOLD=$'\033[1m';   RESET=$'\033[0m'
else
  RED=''; GREEN=''; YELLOW=''; BOLD=''; RESET=''
fi

# ------------------------------------------------------------- timestamps ---
# `date -Is` is GNU-only. This works on both GNU coreutils and BSD/macOS date,
# which matters because I develop on a Mac and run on Ubuntu.
timestamp() { date +%Y-%m-%dT%H:%M:%S%z; }

# ---------------------------------------------------------------- logging ---
log() {                                   # log LEVEL message...
  local level=$1; shift
  local line
  line="$(timestamp) [$HOSTNAME_S] [$level] $*"
  if [ -w "$LOGFILE" ] || { [ ! -e "$LOGFILE" ] && [ -w "$(dirname "$LOGFILE")" ]; }; then
    printf '%s\n' "$line" >> "$LOGFILE"
  else
    # Never die because the log is unwritable -- say so once and carry on.
    if [ -z "${LOG_WARNED:-}" ]; then
      printf '%s\n' "${YELLOW}warning: cannot write $LOGFILE, logging to stderr${RESET}" >&2
      LOG_WARNED=1
    fi
    printf '%s\n' "$line" >&2
  fi
}

# ------------------------------------------------------------ curl errors ---
# The three that actually show up in this exam. Everything else falls through
# to the manual rather than pretending to know.
curl_reason() {
  case "$1" in
    6)  echo "could not resolve host" ;;
    7)  echo "could not connect -- nothing listening / refused" ;;
    28) echo "timed out after ${CURL_TIMEOUT}s" ;;
    *)  echo "see man curl, EXIT CODES" ;;
  esac
}

# ----------------------------------------------------------------- locking ---
# flock on fd 200. -n = fail immediately rather than queue up behind the
# running copy. Taken before the config check so a stampede cannot happen
# even when the config is broken.
if command -v flock >/dev/null 2>&1; then
  exec 200>"$LOCKFILE" || { echo "cannot open lock file $LOCKFILE" >&2; exit 1; }
  if ! flock -n 200; then
    log INFO "another healthcheck.sh is still running (lock $LOCKFILE held) -- exiting quietly"
    exit 0
  fi
else
  # flock is util-linux and is present on Ubuntu; it is NOT on macOS. The first
  # version of this script tested `if ! flock -n 200` directly, and on my Mac
  # the missing binary returned 127, which the script read as "lock held" and
  # exited 0 every single time. A monitoring script that silently does nothing
  # is worse than one that crashes, so the absence is now loud.
  printf '%swarning: flock not found -- running WITHOUT a concurrency lock%s\n' \
    "$YELLOW" "$RESET" >&2
  log WARN "flock unavailable, no concurrency lock held"
fi

# ------------------------------------------------------------ config check ---
if [ ! -f "$CONFIG" ] || [ ! -r "$CONFIG" ]; then
  printf '%sERROR%s config file not found or unreadable: %s\n' "$RED" "$RESET" "$CONFIG" >&2
  log ERROR "config file not found or unreadable: $CONFIG (exit 2)"
  exit 2
fi

log INFO "run start config=$CONFIG pid=$$"
printf '%s== healthcheck %s ==%s  config: %s\n' "$BOLD" "$(date '+%F %T')" "$RESET" "$CONFIG"

# ------------------------------------------------------------- the checks ---
failures=0
checked=0

# The `|| [ -n "$line" ]` keeps the last line even if the file has no trailing
# newline. IFS= and -r stop read from eating whitespace and backslashes.
while IFS= read -r line || [ -n "$line" ]; do
  line="${line%%$'\r'}"                     # tolerate CRLF configs
  line="$(printf '%s' "$line" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')"
  [ -z "$line" ] && continue                # blank
  case "$line" in \#*) continue ;; esac     # comment

  checked=$((checked+1))          # a non-blank, non-comment line is a check

  IFS='|' read -r name url expected <<< "$line"
  if [ -z "${name:-}" ] || [ -z "${url:-}" ] || [ -z "${expected:-}" ]; then
    printf '  %s[BAD ]%s %s\n' "$RED" "$RESET" "malformed line: $line"
    log ERROR "malformed config line: $line"
    failures=$((failures+1)); continue
  fi

  # --max-time bounds the WHOLE request; --connect-timeout bounds only the
  # DNS+TCP phase. Both are needed: a host that accepts the connection and then
  # says nothing would otherwise sit past the 3 second budget.
  #
  # `< /dev/null` is not decoration. Without it curl inherits the loop's stdin,
  # which IS the config file, and reads the remaining lines out from under the
  # while loop -- my first version silently checked only the first service and
  # cheerfully reported "all 1 checks passed".
  #
  # Timing comes from curl's own %{time_total} rather than `date +%s%N`,
  # because BSD date has no %N and emitted a literal "N" when I tested on macOS.
  curl_out=$(curl -s -o /dev/null \
                  --max-time "$CURL_TIMEOUT" --connect-timeout "$CURL_TIMEOUT" \
                  -w '%{http_code} %{time_total}' "$url" < /dev/null 2>/dev/null)
  curl_rc=$?
  read -r code elapsed_s <<< "$curl_out"
  code=${code:-000}
  elapsed_ms=$(awk -v t="${elapsed_s:-0}" 'BEGIN { printf "%.0f", t * 1000 }')

  if [ "$code" = "$expected" ]; then
    printf '  %s[ OK ]%s %-10s %-42s %s in %sms\n' \
      "$GREEN" "$RESET" "$name" "$url" "$code" "$elapsed_ms"
    log INFO "OK   name=$name url=$url code=$code expected=$expected ms=$elapsed_ms"
  else
    reason="got $code, expected $expected"
    [ "$curl_rc" -ne 0 ] && reason="$reason (curl exit $curl_rc: $(curl_reason "$curl_rc"))"
    printf '  %s[FAIL]%s %-10s %-42s %s in %sms\n' \
      "$RED" "$RESET" "$name" "$url" "$reason" "$elapsed_ms"
    log ERROR "FAIL name=$name url=$url code=$code expected=$expected curl_rc=$curl_rc ms=$elapsed_ms"
    failures=$((failures+1))
  fi
done < "$CONFIG"

# ---------------------------------------------------------------- disk ------
# -P forces POSIX single-line output so awk sees a predictable column 5 even
# when the device name is long enough to wrap.
disk_pct=$(df -P / | awk 'NR==2 {gsub(/%/,"",$5); print $5}')
disk_avail=$(df -Ph / | awk 'NR==2 {print $4}')
if [ "${disk_pct:-0}" -ge "$DISK_THRESHOLD" ]; then
  printf '  %s[WARN]%s %-10s / is %s%% full (%s free, threshold %s%%)\n' \
    "$YELLOW" "$RESET" "disk" "$disk_pct" "$disk_avail" "$DISK_THRESHOLD"
  log WARN "disk / at ${disk_pct}% (threshold ${DISK_THRESHOLD}%, ${disk_avail} free)"
else
  printf '  %s[ OK ]%s %-10s / is %s%% full (%s free)\n' \
    "$GREEN" "$RESET" "disk" "$disk_pct" "$disk_avail"
  log INFO "OK   disk / at ${disk_pct}% (${disk_avail} free)"
fi

# --------------------------------------------------------------- summary ----
if [ "$failures" -eq 0 ]; then
  printf '%s%s all %s checks passed%s\n' "$BOLD" "$GREEN" "$checked" "$RESET"
  log INFO "run end status=ok checked=$checked failures=0 exit=0"
  exit 0
else
  printf '%s%s %s of %s checks FAILED%s\n' "$BOLD" "$RED" "$failures" "$checked" "$RESET"
  log ERROR "run end status=degraded checked=$checked failures=$failures exit=1"
  exit 1
fi
