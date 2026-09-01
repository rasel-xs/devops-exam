#!/usr/bin/env bash
# A1 proof table -- runs all 12 required checks and prints PASS/FAIL per row.
# Run as root on the VPS:
#
#   echo "$EXAM_TOKEN | $(date)"
#   sudo -E bash verify-a1.sh 2>&1 | tee ../evidence/a1-proof-table.txt
#
# Capture it as a screenshot, or as a typescript:
#   script -q -c 'sudo -E bash verify-a1.sh' ../evidence/a1-proof-table.txt

APP=/srv/app
PASS=0; FAIL=0

echo "EXAM_TOKEN: ${EXAM_TOKEN:-<<NOT SET -- run the export first>>}"
echo "date      : $(date)"
echo "host      : $(hostname)"
echo

# run <n> <user> <expect: ok|denied> <command...>
run() {
  local n=$1 user=$2 expect=$3; shift 3
  local out rc
  out=$(sudo -u "$user" bash -c "$*" 2>&1); rc=$?
  local got=ok; [ $rc -ne 0 ] && got=denied
  local verdict="PASS"; [ "$got" != "$expect" ] && verdict="FAIL"
  [ "$verdict" = PASS ] && PASS=$((PASS+1)) || FAIL=$((FAIL+1))
  printf '%-3s %-6s expect=%-6s rc=%-3s %s\n' "$n" "$user" "$expect" "$rc" "$verdict"
  printf '    $ %s\n' "$*"
  [ -n "$out" ] && printf '    | %s\n' "$(echo "$out" | head -4 | sed 's/$/ /' | paste -sd'\n' - | sed '2,$s/^/    | /')"
  echo
}

echo "=================== A1 PROOF TABLE ==================="
run 1  alice ok     "echo test >> $APP/src/main.js && tail -1 $APP/src/main.js"
run 2  alice ok     "cat $APP/logs/app.log | tail -1"
run 3  alice ok     "sudo -n systemctl restart myapp && systemctl is-active myapp"
run 4  alice denied "cat $APP/secrets/db-password.txt"
run 5  alice denied "sudo -n apt update"
run 6  carol ok     "echo x >> $APP/config/app.conf && tail -1 $APP/config/app.conf"
run 7  carol ok     "cat $APP/secrets/db-password.txt"
run 8  carol denied "rm -f $APP/backups/backup1.tar"
run 9  dan   ok     "ls -l $APP/secrets/"
run 10 dan   denied "cat $APP/secrets/db-password.txt"
run 11 dan   denied "echo x >> $APP/src/main.js"
run 12 dan   denied "sudo -n systemctl restart myapp"

echo "======================================================"
echo "PASS=$PASS FAIL=$FAIL"
echo
echo "--- supporting evidence ---"
echo "\$ sudo -l -U alice"; sudo -l -U alice
echo
echo "\$ sudo -l -U dan";   sudo -l -U dan
echo
echo "\$ getfacl -p $APP/secrets";            getfacl -p "$APP/secrets"
echo "\$ getfacl -p $APP/secrets/db-password.txt"; getfacl -p "$APP/secrets/db-password.txt"
echo "\$ ls -la $APP/backups"; ls -la "$APP/backups"
echo "\$ lsattr $APP/backups"; lsattr "$APP/backups"
echo "\$ id alice; id carol; id dan"; id alice; id carol; id dan

[ "$FAIL" -eq 0 ]
