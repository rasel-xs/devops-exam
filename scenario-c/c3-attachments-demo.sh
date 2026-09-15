#!/usr/bin/env bash
# Scenario C3, tasks 55-58 -- every proof, in order, against the live service.
#
# Needs only bash + curl: no AWS credentials. The APP signs the URLs; this client
# just uses them, exactly as a browser would. Runs on the laptop or the VPS:
#
#   bash c3-attachments-demo.sh 2>&1 | tee c3-attachments-demo.txt
#
# Optional first argument: which part to run (55, 56, 57, 58). Default: all.
set -uo pipefail

EXAM_TOKEN=root-vmi3536696-1788282556-1536d427
ALB=http://abdur-notes-alb-2056595441.eu-north-1.elb.amazonaws.com
BUCKET_URL=https://abdur-notes-750069566598.s3.eu-north-1.amazonaws.com
ONLY=${1:-all}
WORK=$(mktemp -d); trap 'rm -rf "$WORK"' EXIT

stamp() { echo; echo "EXAM_TOKEN: $EXAM_TOKEN | $(date)"; }
step()  { stamp; echo "=== $* ==="; }
want()  { [ "$ONLY" = all ] || [ "$ONLY" = "$1" ]; }
field() { sed -n "s/.*\"$1\":\"\([^\"]*\)\".*/\1/p"; }        # tiny JSON field reader
enc()   { printf '%s' "$1" | sed 's|/|%2F|g'; }                # key -> one path segment

upload_url() {   # tenant filename visibility
  curl -sS -X POST "$ALB/api/attachments/upload-url" \
    -H "X-Tenant: $1" -H 'Content-Type: application/json' \
    -d "{\"filename\":\"$2\",\"visibility\":\"$3\"}"
}
download_url() { # tenant key
  curl -sS "$ALB/api/attachments/$(enc "$2")/download-url" -H "X-Tenant: $1"
}
put_file() {     # url file
  curl -sS -o /dev/null -w "HTTP %{http_code}\n" -X PUT --upload-file "$2" "$1"
}
show() {         # label url  -- prints status and body (S3 errors are XML)
  echo "--- $1"
  curl -sS -w "\n[HTTP %{http_code}]\n" "$2"
}

stamp
echo "service: $(curl -sS "$ALB/healthz")"

# -----------------------------------------------------------------------------
# Setup used by every part: one private file for acme, one for globex.
echo "acme invoice 001 -- private to acme -- $(date)" > "$WORK/acme-invoice-001.txt"
echo "globex payroll -- private to globex -- $(date)" > "$WORK/globex-payroll.txt"
echo "acme public logo placeholder -- $(date)"        > "$WORK/acme-logo.txt"

if want 55; then
  step "TASK 55 -- presigned upload into a private bucket"
  echo "\$ curl -X POST $ALB/api/attachments/upload-url -H 'X-Tenant: acme' -d '{\"filename\":\"acme-invoice-001.txt\"}'"
  R=$(upload_url acme acme-invoice-001.txt private); echo "$R"
  ACME_KEY=$(printf '%s' "$R" | field key); URL=$(printf '%s' "$R" | field url)
  echo
  echo "generated URL (valid 300 s):"; echo "$URL"
  echo
  echo "\$ curl -X PUT --upload-file acme-invoice-001.txt '<the URL above>'"
  put_file "$URL" "$WORK/acme-invoice-001.txt"
else
  R=$(upload_url acme acme-invoice-001.txt private)
  ACME_KEY=$(printf '%s' "$R" | field key)
  put_file "$(printf '%s' "$R" | field url)" "$WORK/acme-invoice-001.txt" >/dev/null
  echo "(setup: acme uploaded $ACME_KEY)"
fi
R=$(upload_url globex globex-payroll.txt private)
GLOBEX_KEY=$(printf '%s' "$R" | field key)
put_file "$(printf '%s' "$R" | field url)" "$WORK/globex-payroll.txt" >/dev/null
echo "(setup: globex uploaded $GLOBEX_KEY)"

if want 56; then
  step "TASK 56 -- presigned download, 60 second expiry"
  R=$(download_url acme "$ACME_KEY"); echo "$R"
  URL=$(printf '%s' "$R" | field url)
  show "open it now (works)" "$URL"
  echo
  echo "waiting 61 seconds..."
  for s in 10 20 30 40 50 60; do sleep 10; echo "  ${s}s"; done; sleep 1; echo "  61s"
  show "open the SAME URL again after 61 s -- S3's exact error" "$URL"
  echo
  show "a plain, unsigned request for the same object" "$BUCKET_URL/$ACME_KEY"
fi

if want 57; then
  step "TASK 57 -- two access patterns in one bucket"
  R=$(upload_url acme acme-logo.txt public); echo "$R"
  PUB_KEY=$(printf '%s' "$R" | field key); PUB_URL=$(printf '%s' "$R" | field publicUrl)
  put_file "$(printf '%s' "$R" | field url)" "$WORK/acme-logo.txt"
  echo
  show "57a. plain URL to public/ -- no signature, anyone" "$PUB_URL"
  echo
  show "57b. plain URL to tenants/acme/private/ -- no signature" "$BUCKET_URL/$ACME_KEY"
  echo
  URL=$(download_url acme "$ACME_KEY" | field url)
  show "57c. presigned URL to that same private file" "$URL"
fi

if want 58; then
  step "TASK 58 -- tenant isolation: acme asks for a globex key"
  echo "globex's key (acme knows it): $GLOBEX_KEY"
  echo
  echo "\$ curl $ALB/api/attachments/<globex key>/download-url -H 'X-Tenant: acme'"
  curl -sS -w "\n[HTTP %{http_code}]\n" "$ALB/api/attachments/$(enc "$GLOBEX_KEY")/download-url" -H 'X-Tenant: acme'
  echo
  echo "control -- the owner asks for the same key:"
  curl -sS -o /dev/null -w "  globex -> [HTTP %{http_code}] (a URL was signed)\n" \
    "$ALB/api/attachments/$(enc "$GLOBEX_KEY")/download-url" -H 'X-Tenant: globex'
fi

stamp
echo "=== done ==="
