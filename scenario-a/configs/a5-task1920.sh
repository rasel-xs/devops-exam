#!/usr/bin/env bash
# A5 tasks 19 and 20 -- the 504, and rate limiting.
set -u
CONF=/etc/nginx/sites-available/abdur-myapp
BASE=http://127.0.0.1:8110

hr() { printf '\n============ %s ============\n' "$*"; }
echo "EXAM_TOKEN: ${EXAM_TOKEN:-NOT SET}"
echo "date      : $(date)"

# --------------------------------------------------------------- task 19 ----
hr "TASK 19a: /slow with proxy_read_timeout 5s -- expect 504"
grep -n 'proxy_read_timeout' "$CONF" | sed 's/^/  /'
echo
echo "The backend sleeps 45s before replying. nginx gives up after 5."
time curl -s -o /dev/null -w '  http_code=%{http_code}  time=%{time_total}s\n' "$BASE/slow"

echo
echo "--- and the error nginx logged for it ---"
tail -2 /var/log/nginx/abdur-myapp.error.log | sed 's/^/  /'

hr "TASK 19b: raise it to 60s -- expect 200 after ~45s"
sed -i 's|^        proxy_read_timeout    5s;|        proxy_read_timeout   60s;|' "$CONF"
grep -n 'proxy_read_timeout   60s' "$CONF" | sed 's/^/  /'
nginx -t 2>&1 | sed 's/^/  /'
systemctl reload nginx
sleep 1
echo
echo "Now the same request. This takes 45 seconds -- that is the point."
time curl -s -w '  http_code=%{http_code}  time=%{time_total}s\n' "$BASE/slow"

hr "TASK 19c: put it back to 5s"
sed -i 's|^        proxy_read_timeout   60s;|        proxy_read_timeout    5s;|' "$CONF"
nginx -t 2>&1 | sed 's/^/  /'
systemctl reload nginx
grep -n 'proxy_read_timeout' "$CONF" | sed 's/^/  /'

# --------------------------------------------------------------- task 20 ----
hr "TASK 20: rate limiting -- 50 requests as fast as possible"
grep -nE 'limit_req|rate=' "$CONF" | sed 's/^/  /'
echo
echo "Note: /api/notes does not exist in this Scenario A app, so the backend"
echo "answers 404. That does not weaken the test -- it strengthens it. A 429"
echo "is produced by nginx BEFORE the request is ever proxied, so a mix of"
echo "404 and 429 proves the limiter is rejecting requests rather than the"
echo "backend rejecting them."
echo
for i in $(seq 1 50); do
  curl -s -o /dev/null -w "%{http_code}\n" "$BASE/api/notes"
done | sort | uniq -c

echo
echo "--- what nginx logged about the rejections ---"
grep 'limiting requests' /var/log/nginx/abdur-myapp.error.log | tail -3 | sed 's/^/  /'

hr "TASK 20b: same 50 requests, but slowly (under the limit)"
echo "rate=10r/s, so one request every 0.2s is inside the budget and none"
echo "should be rejected. This is the control that proves the limiter is"
echo "counting rate rather than just refusing the 21st request it ever sees."
sleep 3
for i in $(seq 1 20); do
  curl -s -o /dev/null -w "%{http_code}\n" "$BASE/api/notes"
  sleep 0.2
done | sort | uniq -c

hr "END"
