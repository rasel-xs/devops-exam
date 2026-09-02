#!/usr/bin/env bash
# A3 evidence -- task 10 (break tests) and the task 9 requirement 7 lock guard.
#
#   cd /root/abdur-exam/scenario-a
#   script -q -c 'bash configs/a3-tests.sh' evidence/a3-session.txt
set -u
HC=/usr/local/bin/abdur-healthcheck.sh
CONF_DIR=/etc/abdur-healthcheck

hr() { printf '\n============ %s ============\n' "$*"; }

echo "EXAM_TOKEN: ${EXAM_TOKEN:-NOT SET}"
echo "date      : $(date)"

hr "TASK 9: normal run -- a passing and a failing service"
"$HC" "$CONF_DIR/checks.conf"
echo "exit code = $?   (1 = at least one service failed)"

hr "TASK 10 break test 1: config file that does not exist"
"$HC" /nope/does-not-exist.conf
echo "exit code = $?   (2 = config missing or unreadable, as specified)"

hr "TASK 10 break test 1b: config that EXISTS but is unreadable"
# A different failure that must also be exit 2, not "0 services, all healthy".
# This is the one that bites in cron, where the job may run as another user.
install -m 000 /dev/null /tmp/abdur-unreadable.conf
sudo -u abdur_alice "$HC" /tmp/abdur-unreadable.conf
echo "exit code = $?   (2 = correct: existence is not the same as readability)"
rm -f /tmp/abdur-unreadable.conf

hr "TASK 10 break test 2: a URL that does not resolve at all"
echo "--- the config ---"
cat configs/checks-broken.conf
echo
echo "--- running it (timing it, to prove it does not hang) ---"
time "$HC" configs/checks-broken.conf
echo "exit code = $?   (1 = failures, and it finished in about a second)"

hr "TASK 9 requirement 7: two copies must not run at once"
echo "Starting a slow run in the background (3 blackholed IPs, ~9s)..."
"$HC" "$CONF_DIR/slow.conf" >/tmp/abdur-slow-run.log 2>&1 &
FIRST=$!
sleep 2
echo "First copy is PID $FIRST and still running:"
ps -o pid=,etime=,cmd= -p $FIRST
echo
echo "Now starting a SECOND copy while the first still holds the lock:"
"$HC" "$CONF_DIR/checks.conf"
echo "second copy exit code = $?   (0 = it declined quietly, as cron requires)"
echo
echo "--- what the log says about it ---"
grep 'still running' /var/log/abdur-healthcheck.log | tail -3
echo
echo "Waiting for the first copy to finish..."
wait $FIRST
echo "first copy exit code = $?"
echo "--- and its output, to show it really was working the whole time ---"
cat /tmp/abdur-slow-run.log

hr "TASK 11: cron"
echo "--- crontab -l ---"
crontab -l
echo
echo "--- log entries from cron runs (look for distinct timestamps) ---"
tail -25 /var/log/abdur-healthcheck.log
hr "END"
