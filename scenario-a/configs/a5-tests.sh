#!/usr/bin/env bash
# A5 evidence generator. Run on the VPS, capture the whole terminal.
#   echo "$EXAM_TOKEN | $(date)"; bash a5-tests.sh | tee ../evidence/a5-tests.txt
set -u
echo "EXAM_TOKEN: ${EXAM_TOKEN:-NOT SET} | $(date)"; echo

echo "=== task 16: what the app sees through nginx ==="
echo "--- direct to backend (no proxy) ---"
curl -s http://127.0.0.1:3101/whoami | head -8
echo "--- through nginx on :8110 ---"
curl -s http://127.0.0.1:8110/whoami | head -8
echo "  (from your LAPTOP, run: curl -s http://<server-ip>/whoami | jq)"
echo

echo "=== task 17: distribution over 100 requests ==="
for i in $(seq 1 100); do curl -s http://127.0.0.1:8110/ ; done | sort | uniq -c
echo

echo "=== task 18: failover loop -- run this in a second terminal, then stop 3102 ==="
cat <<'LOOP'
  while true; do
    echo "$(date +%T) $(curl -s --max-time 2 http://localhost:8110/ || echo FAILED)"
    sleep 0.5
  done | tee ../evidence/a5-failover-loop.txt
  # other terminal:
  sudo systemctl stop abdur-abdur-myapp@3102   ; sleep 30
  sudo systemctl start abdur-abdur-myapp@3102
LOOP
echo

echo "=== task 19: the slow endpoint ==="
echo "--- with proxy_read_timeout 5s (expect 504) ---"
time curl -s -o /dev/null -w '%{http_code} in %{time_total}s\n' http://127.0.0.1:8110/slow
echo "  now: sudo sed -i 's/proxy_read_timeout    5s;/proxy_read_timeout   60s;/' \\"
echo "        /etc/nginx/sites-available/abdur-myapp && sudo nginx -t && sudo systemctl reload nginx"
echo "  then re-run the line above and expect 200 in ~45s"
echo

echo "=== task 20: rate limiting, 50 requests as fast as possible ==="
for i in $(seq 1 50); do
  curl -s -o /dev/null -w "%{http_code}\n" http://127.0.0.1:8110/api/notes
done | sort | uniq -c
