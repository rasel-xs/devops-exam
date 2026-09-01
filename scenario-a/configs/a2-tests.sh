#!/usr/bin/env bash
# A2 evidence generator -- recreates the whole "who has my port?" scenario and
# runs tasks 5, 6 and 7 in one capture.
#
# Record it as a terminal session:
#   cd /root/abdur-exam/scenario-a
#   script -q -c 'bash configs/a2-tests.sh' evidence/a2-session.txt
#
# Ports are namespaced for this shared VPS: 8180 replaces the brief's 8080
# (taken by another student) and 8181 replaces 9090.
set -u
export SYSTEMD_COLORS=0          # keep the transcript readable

PORT_ROOT=8180        # started by root
PORT_USER=8181        # started by abdur_alice -- the controlled comparison
UNIT=abdur-myapp

hr() { printf '\n============ %s ============\n' "$*"; }

echo "EXAM_TOKEN: ${EXAM_TOKEN:-NOT SET}"
echo "date      : $(date)"
echo "host      : $(hostname)"

# --------------------------------------------------------------- setup ------
hr "SETUP: creating the mystery"
pkill -f "http.server $PORT_ROOT" 2>/dev/null
pkill -f "http.server $PORT_USER" 2>/dev/null
sleep 1
nohup python3 -m http.server "$PORT_ROOT" >/tmp/abdur-$PORT_ROOT.log 2>&1 &
sudo -u abdur_alice nohup python3 -m http.server "$PORT_USER" \
     >/tmp/abdur-$PORT_USER.log 2>&1 &
sleep 2
ss -lntp "sport = :$PORT_ROOT or sport = :$PORT_USER"

PID=$(ss  -lntpH "sport = :$PORT_ROOT" | grep -oP 'pid=\K[0-9]+' | head -1)
PID2=$(ss -lntpH "sport = :$PORT_USER" | grep -oP 'pid=\K[0-9]+' | head -1)

# --------------------------------------------------------------- task 5 -----
hr "TASK 5: identify what holds port $PORT_ROOT"
echo "1. PID          : $PID"
echo "2. Binary path  : $(readlink -f /proc/$PID/exe)"
echo "3. User         : $(ps -o user= -p $PID)"
echo "4. Start time   : $(ps -o lstart= -p $PID)"
# cmdline is NUL-separated, so `cat` would run the arguments together.
echo -n "5. Command line : "; tr '\0' ' ' < /proc/$PID/cmdline; echo
echo
echo "--- ss ---";   ss -lptn "sport = :$PORT_ROOT"
echo "--- lsof ---"; lsof -i :$PORT_ROOT

# --------------------------------------------------------------- task 6 -----
hr "TASK 6: same commands, with and without privilege"
echo "### WITHOUT sudo -- as abdur_alice ###"
echo "--- ss -lptn ---"
sudo -u abdur_alice ss -lptn "sport = :$PORT_ROOT or sport = :$PORT_USER"
echo "--- lsof -i :$PORT_ROOT ---"
sudo -u abdur_alice lsof -i :$PORT_ROOT; echo "  (exit code $?)"

echo
echo "### WITH sudo -- as root ###"
echo "--- ss -lptn ---"
ss -lptn "sport = :$PORT_ROOT or sport = :$PORT_USER"
echo "--- lsof -i :$PORT_ROOT ---"
lsof -i :$PORT_ROOT

echo
echo "### WHY the difference ###"
echo "ss has to map socket inode -> process by walking /proc/<pid>/fd/."
echo "--- permissions on root's fd directory ---"
ls -ld /proc/$PID/fd
echo "--- can abdur_alice open it? ---"
sudo -u abdur_alice ls /proc/$PID/fd
echo "--- but the socket table itself is world readable ---"
sudo -u abdur_alice head -3 /proc/net/tcp

# --------------------------------------------------------------- task 7 -----
hr "TASK 7a: manual, systemd, or cron?"
echo "--- cgroup of the mystery process ---"
cat /proc/$PID/cgroup
echo "--- cgroup of a known systemd service, for comparison ---"
MYAPP_PID=$(systemctl show -p MainPID --value "$UNIT")
cat /proc/$MYAPP_PID/cgroup
echo
echo "--- parent process ---"
ps -o pid=,ppid=,user=,cmd= -p "$PID"
PPID_V=$(ps -o ppid= -p "$PID" | tr -d ' ')
echo "  parent -> $(ps -o cmd= -p "$PPID_V")"
echo
echo "--- what does systemd think this PID belongs to? ---"
systemctl status "$PID" --no-pager 2>&1 | head -4
echo
echo "--- anything in cron? ---"
grep -rn "$PORT_ROOT" /etc/cron* /var/spool/cron/crontabs/ 2>/dev/null \
  || echo "  nothing in cron"
echo
echo "VERDICT: user.slice + a bash parent + no unit file = started by hand."

hr "TASK 7b: what kill -9 does to a systemd-managed process"
OLD=$(systemctl show -p MainPID --value "$UNIT")
echo "PID before kill : $OLD"
kill -9 "$OLD"
echo ">>> kill -9 $OLD"
sleep 3
echo "PID after 3s    : $(systemctl show -p MainPID --value "$UNIT")"
echo "unit state      : $(systemctl is-active "$UNIT")"
echo "--- what the journal recorded ---"
journalctl -u "$UNIT" -n 6 --no-pager

hr "TASK 7c: killing the manual process the right way"
echo "--- before ---"
ss -lntp "sport = :$PORT_ROOT"
kill "$PID"
echo ">>> kill $PID    (SIGTERM, not -9: the process gets to clean up)"
sleep 2
echo "--- after ---"
ss -lntpH "sport = :$PORT_ROOT" | grep -q . \
  && echo "  still held" || echo "  port $PORT_ROOT is now FREE"

# ---------------------------------------------------- task 8 preparation ----
hr "TASK 8: set up the two failure modes, then test from the laptop"
pkill -f "http.server $PORT_USER" 2>/dev/null
sleep 1
# 8180 on every interface -- reachable from outside.
nohup python3 -m http.server 8180 --bind 0.0.0.0   >/tmp/abdur-8180.log 2>&1 &
# 8182 on loopback only -- the app is up, and still unreachable from outside.
nohup python3 -m http.server 8182 --bind 127.0.0.1 >/tmp/abdur-8182.log 2>&1 &
sleep 2

echo "--- firewall state ---"
ufw status 2>/dev/null || echo "  ufw not installed"
iptables -L INPUT -n --line-numbers | head -8
echo "  NOTE: the DROP on 8080 is another student's rule on this shared box."
echo "        I did not add it and will not remove it -- it conveniently"
echo "        provides the 'timed out' case to compare against."
echo
echo "--- bind addresses: this column is the whole answer ---"
ss -lntp | grep -E ':8180|:8182'
echo
echo "--- from INSIDE the server, both work ---"
curl -s -o /dev/null -w "  8180 -> %{http_code}\n" http://127.0.0.1:8180/
curl -s -o /dev/null -w "  8182 -> %{http_code}\n" http://127.0.0.1:8182/
echo
echo "Now run this ON THE LAPTOP (evidence/a2-task8-from-laptop.txt):"
cat <<'LAPTOP'
    export EXAM_TOKEN="root-vmi3536696-1788282556-1536d427"
    echo "$EXAM_TOKEN | $(date)"
    for p in 8180 8182 8080 9999; do
      echo "======== port $p ========"
      curl -sS -m 6 -o /dev/null \
           -w "  OK: http_code=%{http_code} time=%{time_total}s\n" \
           "http://169.58.246.108:$p/" || echo "  curl exit code = $?"
    done
LAPTOP
echo
echo "Afterwards, clean up with:"
echo "    pkill -f 'http.server 8180'; pkill -f 'http.server 8182'"
hr "END"
