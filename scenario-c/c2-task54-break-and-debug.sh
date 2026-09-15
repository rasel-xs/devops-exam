#!/usr/bin/env bash
# Scenario C task 54 -- break one thing on purpose, debug it in a fixed order,
# fix it, prove it is fixed.
#
#   bash c2-task54-break-and-debug.sh 2>&1 | tee evidence/c2-task54-break-and-debug.txt
#
# THE BREAK: the target group's health check path becomes /readyz-typo, a path
# the app does not serve (404). This is the realistic version of the fault --
# someone renames an endpoint, or types the path into the console -- and nothing
# about the app, the image, the network or the task definition changes. Only
# the load balancer's opinion of the tasks does.
set -uo pipefail
export AWS_REGION=eu-north-1 AWS_DEFAULT_REGION=eu-north-1 AWS_PAGER=""

EXAM_TOKEN=root-vmi3536696-1788282556-1536d427
EXPECTED_ARN="arn:aws:iam::750069566598:user/rasel"
CLUSTER=abdur-exam-cluster
SERVICE=abdur-notes-svc
TG_NAME=abdur-notes-tg
APP_SG=sg-0cdfa2df06a0ca703
ALB=http://abdur-notes-alb-2056595441.eu-north-1.elb.amazonaws.com
GOOD_PATH=/readyz
BAD_PATH=/readyz-typo

stamp() { echo; echo "EXAM_TOKEN: $EXAM_TOKEN | $(date)"; }
die()   { echo; echo "STOPPED: $*" >&2; exit 1; }
step()  { stamp; echo "=== $* ==="; }

ARN=$(aws sts get-caller-identity --query Arn --output text) || die "sts failed (run: aws login)"
[ "$ARN" = "$EXPECTED_ARN" ] || die "running as $ARN"
TG_ARN=$(aws elbv2 describe-target-groups --names "$TG_NAME" \
  --query 'TargetGroups[0].TargetGroupArn' --output text) || die "no target group"

# If anything below fails half-way, never leave the service broken.
restore() { aws elbv2 modify-target-group --target-group-arn "$TG_ARN" \
              --health-check-path "$GOOD_PATH" >/dev/null 2>&1; }
trap 'restore' EXIT

targets() {
  aws elbv2 describe-target-health --target-group-arn "$TG_ARN" \
    --query 'TargetHealthDescriptions[].[Target.Id,TargetHealth.State,TargetHealth.Reason]' \
    --output text | awk '{ printf "%s=%s(%s) ", $1, $2, $3 }'
}
counts() {
  aws ecs describe-services --cluster "$CLUSTER" --services "$SERVICE" \
    --query 'services[0].[desiredCount,runningCount,pendingCount]' --output text | tr '\t' '/'
}
watch_line() {
  local code
  code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 "$ALB/healthz") || code=000
  printf '%s  ALB /healthz=%s  desired/running/pending=%s  targets: %s\n' \
    "$(date +%H:%M:%S)" "$code" "$(counts)" "$(targets)"
}

# =============================================================================
step "0. healthy baseline"
aws elbv2 describe-target-groups --target-group-arns "$TG_ARN" \
  --query 'TargetGroups[0].{path:HealthCheckPath,port:HealthCheckPort,matcher:Matcher.HttpCode}' --output table
watch_line

# =============================================================================
step "1. BREAK IT: health check path $GOOD_PATH -> $BAD_PATH"
aws elbv2 modify-target-group --target-group-arn "$TG_ARN" --health-check-path "$BAD_PATH" \
  --query 'TargetGroups[0].{path:HealthCheckPath,port:HealthCheckPort,matcher:Matcher.HttpCode}' \
  --output table || die "could not modify the target group"
BROKE_AT=$(date +%s)

step "2. watch it fail, from the outside, for 4 minutes"
while [ $(( $(date +%s) - BROKE_AT )) -lt 240 ]; do watch_line; sleep 20; done

# =============================================================================
# The debugging, in the order I would do it on a real incident. Each check
# either finds the fault or rules a whole layer out, and they run outside-in:
# what the user sees -> what the orchestrator says -> what the load balancer
# says and WHY -> its configuration -> the app -> the network.
# =============================================================================
step "CHECK 1. What does a user see? (the symptom, before any theory)"
for i in 1 2 3 4 5; do
  curl -s -o /dev/null -w "  GET /healthz -> %{http_code} in %{time_total}s\n" --max-time 5 "$ALB/healthz"
done

step "CHECK 2. What does ECS say? (service counts, then its own event log)"
echo "desired/running/pending = $(counts)"
aws ecs describe-services --cluster "$CLUSTER" --services "$SERVICE" \
  --query 'services[0].events[:10].[createdAt,message]' --output text

step "CHECK 3. What does the load balancer think of each target -- and WHY?"
aws elbv2 describe-target-health --target-group-arn "$TG_ARN" \
  --query 'TargetHealthDescriptions[].{ip:Target.Id,port:Target.Port,state:TargetHealth.State,reason:TargetHealth.Reason,description:TargetHealth.Description}' \
  --output table
echo "The Reason code decides where to look next:"
echo "  Target.ResponseCodeMismatch -> the app ANSWERED, with the wrong code: health-check path/matcher, or the app itself"
echo "  Target.Timeout              -> nothing answered: security group, wrong port, app not listening"
echo "  Target.FailedHealthChecks   -> connection-level failure"

step "CHECK 4. The health check configuration -- is it asking the right question?"
aws elbv2 describe-target-groups --target-group-arns "$TG_ARN" \
  --query 'TargetGroups[0].{path:HealthCheckPath,port:HealthCheckPort,protocol:HealthCheckProtocol,matcher:Matcher.HttpCode,interval:HealthCheckIntervalSeconds,healthy:HealthyThresholdCount,unhealthy:UnhealthyThresholdCount}' \
  --output table

step "CHECK 5. Is the app itself alive? (ECS container health check runs INSIDE the task, on /healthz)"
TASKS=$(aws ecs list-tasks --cluster "$CLUSTER" --service-name "$SERVICE" --query 'taskArns' --output text)
[ -n "$TASKS" ] && aws ecs describe-tasks --cluster "$CLUSTER" --tasks $TASKS \
  --query "tasks[].{task:taskArn,ip:attachments[0].details[?name=='privateIPv4Address']|[0].value,last:lastStatus,containerHealth:healthStatus,started:startedAt}" \
  --output table

step "CHECK 6. What does the app answer on the path the ALB is probing, versus the right one?"
# The tasks have no inbound path except via the ALB, so ask through the ALB.
for p in "$BAD_PATH" "$GOOD_PATH"; do
  printf '  GET %-13s -> ' "$p"
  curl -s --max-time 5 -w '  [HTTP %{http_code}]\n' "$ALB$p"
done

step "CHECK 7. Network, only to rule it out: does the app SG still admit the ALB on 3000?"
aws ec2 describe-security-groups --group-ids "$APP_SG" \
  --query 'SecurityGroups[0].IpPermissions[].{port:FromPort,fromSg:UserIdGroupPairs[].GroupId}' --output json

# =============================================================================
step "3. FIX: health check path back to $GOOD_PATH"
aws elbv2 modify-target-group --target-group-arn "$TG_ARN" --health-check-path "$GOOD_PATH" \
  --query 'TargetGroups[0].{path:HealthCheckPath,port:HealthCheckPort,matcher:Matcher.HttpCode}' \
  --output table || die "FIX FAILED -- fix by hand"
FIXED_AT=$(date +%s)

step "4. watch it recover -- until every target is healthy and the service is steady"
while :; do
  watch_line
  states=$(aws elbv2 describe-target-health --target-group-arn "$TG_ARN" \
    --query 'TargetHealthDescriptions[].TargetHealth.State' --output text)
  run=$(aws ecs describe-services --cluster "$CLUSTER" --services "$SERVICE" \
    --query 'services[0].[runningCount,desiredCount]' --output text | tr '\t' ' ')
  set -- $run
  if [ -n "$states" ] && ! printf '%s' "$states" | grep -qv healthy && [ "$1" = "$2" ] \
     && [ "$(printf '%s\n' $states | wc -l | tr -d ' ')" = "$2" ]; then
    break
  fi
  [ $(( $(date +%s) - FIXED_AT )) -gt 600 ] && { echo "not recovered after 10 min"; break; }
  sleep 15
done
echo "recovered $(( $(date +%s) - FIXED_AT )) s after the fix"
aws ecs wait services-stable --cluster "$CLUSTER" --services "$SERVICE" || true

step "5. fixed state"
aws elbv2 describe-target-health --target-group-arn "$TG_ARN" \
  --query 'TargetHealthDescriptions[].{ip:Target.Id,state:TargetHealth.State}' --output table
for i in $(seq -w 1 6); do
  echo "request $i  $(curl -s --max-time 5 "$ALB/healthz")"
done
echo "--- service events since the break (newest first)"
aws ecs describe-services --cluster "$CLUSTER" --services "$SERVICE" \
  --query 'services[0].events[:25].[createdAt,message]' --output text

stamp
echo "=== done ==="
