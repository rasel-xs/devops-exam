#!/usr/bin/env bash
# Scenario C task 52 -- target-tracking autoscaling on abdur-notes-svc, then
# actually trigger it and watch it scale out and back in.
#
#   bash c2-task52-autoscaling.sh 2>&1 | tee evidence/c2-task52-autoscaling.txt
#
# Runs for roughly 30-40 minutes: 5 minutes of load, then waiting for scale-in,
# which target tracking deliberately does slowly.
set -uo pipefail
export AWS_REGION=eu-north-1 AWS_DEFAULT_REGION=eu-north-1 AWS_PAGER=""

EXAM_TOKEN=root-vmi3536696-1788282556-1536d427
EXPECTED_ARN="arn:aws:iam::750069566598:user/rasel"
CLUSTER=abdur-exam-cluster
SERVICE=abdur-notes-svc
RESOURCE_ID="service/$CLUSTER/$SERVICE"
POLICY=abdur-notes-cpu50
ALB=http://abdur-notes-alb-2056595441.eu-north-1.elb.amazonaws.com
LOAD_URL="$ALB/api/search?q=abc"
LOAD_MINUTES=5
# Run 1 (evidence/c2-task52-autoscaling-run1-c50.txt) used the brief's -c 50 and
# did NOT scale: service CPU plateaued at 40 %. The limit was the client, not the
# app -- from Dhaka to Stockholm the fastest response was 185 ms, i.e. that is
# the network round trip, so 50 workers can only send ~213 requests/s however
# idle the tasks are. Run 2 raises concurrency so the request rate, not the
# connection count, crosses the 50 % target.
CONCURRENCY=${CONCURRENCY:-50}

stamp() { echo; echo "EXAM_TOKEN: $EXAM_TOKEN | $(date)"; }
die()   { echo; echo "STOPPED: $*" >&2; exit 1; }
step()  { stamp; echo "=== $* ==="; }
utc()   { date -u -v"$1" +%Y-%m-%dT%H:%M:%SZ; }     # macOS date: utc -5M

# =============================================================================
step "0. identity"
ARN=$(aws sts get-caller-identity --query Arn --output text) || die "sts failed (run: aws login)"
[ "$ARN" = "$EXPECTED_ARN" ] || die "running as $ARN"
echo "identity: $ARN"
command -v hey >/dev/null || die "hey not installed"

# =============================================================================
step "1. Container Insights on $CLUSTER -- so the running-task count is a graph, not a moment"
# Plain AWS/ECS metrics give CPU and memory only. Container Insights adds
# RunningTaskCount per service, which is what proves "rose above 2 and came
# back". Costs a few cents for the hours it is on; scoped to my cluster only.
aws ecs update-cluster-settings --cluster "$CLUSTER" \
  --settings name=containerInsights,value=enabled \
  --query 'cluster.settings' --output table || die "could not enable Container Insights"

# =============================================================================
step "2. scalable target: min 2, max 6"
# Run 2 (evidence/c2-task52-autoscaling-run2-stopped.txt) stopped here: calling
# register-scalable-target again WITH --tags on a target that already exists is
# a ValidationException (tags on an existing target go through TagResource). So
# register only if it is not there yet.
existing=$(aws application-autoscaling describe-scalable-targets --service-namespace ecs \
  --resource-ids "$RESOURCE_ID" --query 'length(ScalableTargets)' --output text)
if [ "$existing" = "0" ]; then
  aws application-autoscaling register-scalable-target \
    --service-namespace ecs --scalable-dimension ecs:service:DesiredCount \
    --resource-id "$RESOURCE_ID" --min-capacity 2 --max-capacity 6 \
    --tags "exam-token=$EXAM_TOKEN" >/dev/null || die "register-scalable-target failed"
else
  echo "scalable target already registered (run 1); reusing it"
fi
aws application-autoscaling describe-scalable-targets --service-namespace ecs \
  --resource-ids "$RESOURCE_ID" \
  --query 'ScalableTargets[0].{resource:ResourceId,dimension:ScalableDimension,min:MinCapacity,max:MaxCapacity}' \
  --output table

# =============================================================================
step "3. one target-tracking policy: ECSServiceAverageCPUUtilization = 50 %"
# Cooldowns: scale-out 60 s (react to the next breach quickly), scale-in 120 s.
# The AWS defaults are 300 s each; they are shortened only so the demonstration
# fits in an exam session. They do not make scale-in itself fast -- that is
# governed by the scale-in alarm (15 consecutive one-minute datapoints), which
# target tracking creates and which cannot be tuned.
aws application-autoscaling put-scaling-policy \
  --service-namespace ecs --scalable-dimension ecs:service:DesiredCount \
  --resource-id "$RESOURCE_ID" --policy-name "$POLICY" --policy-type TargetTrackingScaling \
  --target-tracking-scaling-policy-configuration '{
      "TargetValue": 50.0,
      "PredefinedMetricSpecification": {"PredefinedMetricType": "ECSServiceAverageCPUUtilization"},
      "ScaleOutCooldown": 60,
      "ScaleInCooldown": 120,
      "DisableScaleIn": false
    }' --output json || die "put-scaling-policy failed"
aws application-autoscaling describe-scaling-policies --service-namespace ecs \
  --resource-id "$RESOURCE_ID" --policy-names "$POLICY" \
  --query 'ScalingPolicies[0].{name:PolicyName,type:PolicyType,config:TargetTrackingScalingPolicyConfiguration,alarms:Alarms[].AlarmName}' \
  --output json
echo "--- the two alarms target tracking created for it"
aws cloudwatch describe-alarms --alarm-name-prefix "TargetTracking-$RESOURCE_ID" \
  --query 'MetricAlarms[].{name:AlarmName,metric:MetricName,op:ComparisonOperator,threshold:Threshold,period:Period,evaluationPeriods:EvaluationPeriods,datapoints:DatapointsToAlarm,state:StateValue}' \
  --output json

# =============================================================================
cpu_now() {
  aws cloudwatch get-metric-statistics --namespace AWS/ECS --metric-name CPUUtilization \
    --dimensions "Name=ClusterName,Value=$CLUSTER" "Name=ServiceName,Value=$SERVICE" \
    --start-time "$(utc -4M)" --end-time "$(utc +0M)" --period 60 --statistics Average \
    --query 'sort_by(Datapoints,&Timestamp)[-1].[Timestamp,Average]' --output text 2>/dev/null
}
snapshot() {
  local counts alarms
  counts=$(aws ecs describe-services --cluster "$CLUSTER" --services "$SERVICE" \
    --query 'services[0].[desiredCount,runningCount,pendingCount]' --output text | tr '\t' '/')
  alarms=$(aws cloudwatch describe-alarms --alarm-name-prefix "TargetTracking-$RESOURCE_ID" \
    --query 'MetricAlarms[].[AlarmName,StateValue]' --output text \
    | awk '{ printf "%s=%s ", ($1 ~ /AlarmHigh/ ? "high" : "low"), $2 }')
  printf '%s  desired/running/pending=%-7s  cpu(last 1-min avg @ time)=%s  alarms: %s\n' \
    "$(date +%H:%M:%S)" "$counts" "$(cpu_now | tr '\t' ' ')" "$alarms"
}

step "4. baseline before load"
snapshot

# =============================================================================
step "5. LOAD: hey -z ${LOAD_MINUTES}m -c ${CONCURRENCY} against /api/search (tenant acme)"
LOAD_START=$(date +%s)
echo "load started $(date +%H:%M:%S)"
hey -z "${LOAD_MINUTES}m" -c "$CONCURRENCY" -H "X-Tenant: acme" "$LOAD_URL" > /tmp/abdur-hey.txt 2>&1 &
HEY_PID=$!
while kill -0 "$HEY_PID" 2>/dev/null; do snapshot; sleep 30; done
wait "$HEY_PID"
LOAD_END=$(date +%s)
echo "load ended $(date +%H:%M:%S) after $(( (LOAD_END - LOAD_START) / 60 )) min"
echo "--- hey summary"
sed -n '/Summary:/,/Response time histogram/p' /tmp/abdur-hey.txt
sed -n '/Status code distribution/,$p' /tmp/abdur-hey.txt

# =============================================================================
step "6. after the load -- wait for scale-in back to 2 (target tracking is slow here on purpose)"
deadline=$(( $(date +%s) + 45*60 ))
while :; do
  snapshot
  desired=$(aws ecs describe-services --cluster "$CLUSTER" --services "$SERVICE" \
    --query 'services[0].desiredCount' --output text)
  running=$(aws ecs describe-services --cluster "$CLUSTER" --services "$SERVICE" \
    --query 'services[0].runningCount' --output text)
  [ "$desired" = "2" ] && [ "$running" = "2" ] && [ $(( $(date +%s) - LOAD_END )) -gt 120 ] && break
  [ "$(date +%s)" -gt "$deadline" ] && { echo "gave up waiting after 45 min"; break; }
  sleep 60
done
echo "back to 2 at $(date +%H:%M:%S), $(( ($(date +%s) - LOAD_END) / 60 )) min after the load stopped"

# =============================================================================
step "7. the record -- scaling activities (newest first)"
aws application-autoscaling describe-scaling-activities --service-namespace ecs \
  --resource-id "$RESOURCE_ID" --max-items 20 \
  --query 'ScalingActivities[].[StartTime,EndTime,StatusCode,Description,Cause]' --output text

stamp
echo "=== service events (newest first) ==="
aws ecs describe-services --cluster "$CLUSTER" --services "$SERVICE" \
  --query 'services[0].events[:30].[createdAt,message]' --output text

stamp
echo "=== alarm history (state changes) ==="
for a in $(aws cloudwatch describe-alarms --alarm-name-prefix "TargetTracking-$RESOURCE_ID" \
             --query 'MetricAlarms[].AlarmName' --output text); do
  echo "--- $a"
  aws cloudwatch describe-alarm-history --alarm-name "$a" --history-item-type StateUpdate \
    --max-records 10 --query 'AlarmHistoryItems[].[Timestamp,HistorySummary]' --output text
done

stamp
echo "=== done ==="
