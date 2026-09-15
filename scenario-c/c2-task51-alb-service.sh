#!/usr/bin/env bash
# Scenario C task 51 -- abdur-notes-api as an ECS service behind an ALB.
#
# Run in AWS CloudShell (eu-north-1), which is already signed in as the console
# user, so no access key is created or stored anywhere:
#   bash c2-task51-alb-service.sh 2>&1 | tee c2-task51-alb-service.txt
#
# Safe to run again: every step looks for an existing abdur-* resource first and
# reuses it. It creates only abdur-* resources and deletes nothing.
#
# Traffic path this builds:
#   internet --80--> abdur-notes-alb-sg (ALB) --3000--> abdur-notes-app-sg (tasks) --5432--> abdur-notes-db-sg (RDS)
set -uo pipefail
#
# Run 1 (evidence/c2-task51-alb-service-run1.txt) stopped at step 1: the rule
# had already been added in the console, but the existence check used
# `...UserIdGroupPairs[?GroupId==x][] | length(@)`, which filters each rule's
# pair list separately and then counts the wrong thing -- it printed 0. Flatten
# first, then filter, then count: `length(...UserIdGroupPairs[] | [?GroupId==x])`.
# The script stopped instead of carrying on, because AWS refused the duplicate.

export AWS_REGION=eu-north-1 AWS_DEFAULT_REGION=eu-north-1
export AWS_PAGER=""            # CloudShell's CLI otherwise opens `less` and the script hangs

EXAM_TOKEN=root-vmi3536696-1788282556-1536d427
ACCOUNT=750069566598
EXPECTED_ARN="arn:aws:iam::$ACCOUNT:user/rasel"

VPC=vpc-064521cd395a04e1c
ALB_SG=sg-03082ef58d9f2db8a     # abdur-notes-alb-sg
APP_SG=sg-0cdfa2df06a0ca703     # abdur-notes-app-sg
CLUSTER=abdur-exam-cluster
TASKDEF=abdur-notes-api:1
CONTAINER=notes-api
TG_NAME=abdur-notes-tg
ALB_NAME=abdur-notes-alb
SERVICE=abdur-notes-svc

stamp() { echo; echo "EXAM_TOKEN: $EXAM_TOKEN | $(date)"; }
die()   { echo; echo "STOPPED: $*" >&2; exit 1; }
step()  { stamp; echo "=== $* ==="; }

# =============================================================================
step "0. who and where -- must be rasel, account $ACCOUNT, eu-north-1"
ARN=$(aws sts get-caller-identity --query Arn --output text) || die "sts failed"
echo "identity: $ARN"
[ "$ARN" = "$EXPECTED_ARN" ] || die "expected $EXPECTED_ARN"
echo "region:   $AWS_REGION"
aws ecs describe-task-definition --task-definition "$TASKDEF" \
  --query 'taskDefinition.{family:family,revision:revision,image:containerDefinitions[0].image}' \
  --output table || die "task definition $TASKDEF not found"

# =============================================================================
step "1. security groups -- app SG must accept 3000 from the ALB SG, and nothing else new"
has_rule=$(aws ec2 describe-security-groups --group-ids "$APP_SG" \
  --query "length(SecurityGroups[0].IpPermissions[?FromPort==\`3000\` && ToPort==\`3000\`].UserIdGroupPairs[] | [?GroupId=='$ALB_SG'])" \
  --output text)
if [ "$has_rule" = "0" ]; then
  echo "rule 3000 <- $ALB_SG missing; adding it"
  aws ec2 authorize-security-group-ingress --group-id "$APP_SG" \
    --ip-permissions "IpProtocol=tcp,FromPort=3000,ToPort=3000,UserIdGroupPairs=[{GroupId=$ALB_SG,Description='from abdur-notes-alb-sg only'}]" \
    >/dev/null || die "could not add the 3000 rule"
else
  echo "rule 3000 <- $ALB_SG already present"
fi
alb_tag=$(aws ec2 describe-security-groups --group-ids "$ALB_SG" \
  --query "SecurityGroups[0].Tags[?Key=='exam-token'].Value | [0]" --output text)
if [ "$alb_tag" != "$EXAM_TOKEN" ]; then
  echo "exam-token tag on $ALB_SG was '$alb_tag'; setting it"
  aws ec2 create-tags --resources "$ALB_SG" --tags "Key=exam-token,Value=$EXAM_TOKEN" || die "tagging failed"
fi
aws ec2 describe-security-groups --group-ids "$ALB_SG" "$APP_SG" \
  --query "SecurityGroups[].{name:GroupName,vpc:VpcId,tag:Tags[?Key=='exam-token']|[0].Value,inbound:IpPermissions[].{port:FromPort,fromCidr:IpRanges[].CidrIp,fromSg:UserIdGroupPairs[].GroupId}}" \
  --output json

# The default VPC has one default subnet per availability zone. An ALB needs at
# least two AZs; the service uses the same subnets so every AZ has a target.
SUBNETS=$(aws ec2 describe-subnets \
  --filters "Name=vpc-id,Values=$VPC" "Name=default-for-az,Values=true" \
  --query 'Subnets[].SubnetId' --output text)
SUBNETS_CSV=$(echo $SUBNETS | tr ' ' ',')
echo "subnets: $SUBNETS"
[ "$(echo $SUBNETS | wc -w)" -ge 2 ] || die "need at least two default subnets"

# =============================================================================
step "2. target group $TG_NAME -- IP targets (Fargate awsvpc), readiness on /readyz"
TG_ARN=$(aws elbv2 describe-target-groups --names "$TG_NAME" \
  --query 'TargetGroups[0].TargetGroupArn' --output text 2>/dev/null) || TG_ARN=""
if [ -z "$TG_ARN" ] || [ "$TG_ARN" = "None" ]; then
  # target-type ip: a Fargate task has its own ENI and IP and no EC2 instance.
  # /readyz touches the database; /healthz (the container health check) does not.
  # A DB outage should take tasks OUT OF ROTATION here, not get them killed.
  TG_ARN=$(aws elbv2 create-target-group \
    --name "$TG_NAME" --target-type ip --vpc-id "$VPC" \
    --protocol HTTP --port 3000 --protocol-version HTTP1 --ip-address-type ipv4 \
    --health-check-protocol HTTP --health-check-path /readyz --health-check-port traffic-port \
    --health-check-interval-seconds 10 --health-check-timeout-seconds 5 \
    --healthy-threshold-count 2 --unhealthy-threshold-count 2 --matcher HttpCode=200 \
    --tags "Key=exam-token,Value=$EXAM_TOKEN" \
    --query 'TargetGroups[0].TargetGroupArn' --output text) || die "create-target-group failed"
  echo "created $TG_ARN"
else
  echo "reusing $TG_ARN"
fi
# Default is 300 s: every deploy or scale-in would wait five minutes per task.
# The app's requests take milliseconds and it drains on SIGTERM, so 30 s is ample.
aws elbv2 modify-target-group-attributes --target-group-arn "$TG_ARN" \
  --attributes Key=deregistration_delay.timeout_seconds,Value=30 >/dev/null || die "attribute change failed"
aws elbv2 describe-target-groups --target-group-arns "$TG_ARN" \
  --query 'TargetGroups[0].{name:TargetGroupName,type:TargetType,port:Port,path:HealthCheckPath,interval:HealthCheckIntervalSeconds,timeout:HealthCheckTimeoutSeconds,healthy:HealthyThresholdCount,unhealthy:UnhealthyThresholdCount,matcher:Matcher.HttpCode}' \
  --output table
aws elbv2 describe-target-group-attributes --target-group-arn "$TG_ARN" \
  --query "Attributes[?Key=='deregistration_delay.timeout_seconds']" --output table

# =============================================================================
step "3. load balancer $ALB_NAME -- internet-facing, every default subnet, ALB SG only"
ALB_ARN=$(aws elbv2 describe-load-balancers --names "$ALB_NAME" \
  --query 'LoadBalancers[0].LoadBalancerArn' --output text 2>/dev/null) || ALB_ARN=""
if [ -z "$ALB_ARN" ] || [ "$ALB_ARN" = "None" ]; then
  ALB_ARN=$(aws elbv2 create-load-balancer \
    --name "$ALB_NAME" --type application --scheme internet-facing --ip-address-type ipv4 \
    --subnets $SUBNETS --security-groups "$ALB_SG" \
    --tags "Key=exam-token,Value=$EXAM_TOKEN" \
    --query 'LoadBalancers[0].LoadBalancerArn' --output text) || die "create-load-balancer failed"
  echo "created $ALB_ARN"
else
  echo "reusing $ALB_ARN"
fi
echo "waiting for the load balancer to become active (usually 2-4 minutes)..."
aws elbv2 wait load-balancer-available --load-balancer-arns "$ALB_ARN" || die "ALB never became active"
DNS=$(aws elbv2 describe-load-balancers --load-balancer-arns "$ALB_ARN" \
  --query 'LoadBalancers[0].DNSName' --output text)
aws elbv2 describe-load-balancers --load-balancer-arns "$ALB_ARN" \
  --query 'LoadBalancers[0].{name:LoadBalancerName,state:State.Code,scheme:Scheme,dns:DNSName,azs:AvailabilityZones[].ZoneName,sg:SecurityGroups}' \
  --output json

LISTENER_ARN=$(aws elbv2 describe-listeners --load-balancer-arn "$ALB_ARN" \
  --query 'Listeners[?Port==`80`].ListenerArn | [0]' --output text)
if [ -z "$LISTENER_ARN" ] || [ "$LISTENER_ARN" = "None" ]; then
  LISTENER_ARN=$(aws elbv2 create-listener --load-balancer-arn "$ALB_ARN" \
    --protocol HTTP --port 80 \
    --default-actions "Type=forward,TargetGroupArn=$TG_ARN" \
    --tags "Key=exam-token,Value=$EXAM_TOKEN" \
    --query 'Listeners[0].ListenerArn' --output text) || die "create-listener failed"
  echo "created listener HTTP:80 -> $TG_NAME"
else
  echo "reusing listener $LISTENER_ARN"
fi

# =============================================================================
step "4. service $SERVICE -- 2 Fargate tasks registered into $TG_NAME"
svc_status=$(aws ecs describe-services --cluster "$CLUSTER" --services "$SERVICE" \
  --query 'services[0].status' --output text 2>/dev/null)
if [ "$svc_status" != "ACTIVE" ]; then
  # assignPublicIp: no NAT gateway in the default VPC, so tasks reach ECR,
  #   CloudWatch Logs and Secrets Manager over the internet. The app SG still
  #   admits only the ALB, so the public address accepts nothing.
  # health-check-grace-period: ignore ALB health for the first 30 s after a task
  #   starts (migrations run first). Longer would slow down replacing a bad task.
  # circuit breaker + rollback: a revision whose tasks keep failing is rolled
  #   back to the last working one instead of retrying forever.
  # minimumHealthyPercent=100/maximumPercent=200: during a deploy, start the new
  #   tasks before stopping old ones -- never fewer than 2 serving.
  aws ecs create-service \
    --cluster "$CLUSTER" --service-name "$SERVICE" \
    --task-definition "$TASKDEF" --desired-count 2 \
    --launch-type FARGATE --platform-version LATEST \
    --network-configuration "awsvpcConfiguration={subnets=[$SUBNETS_CSV],securityGroups=[$APP_SG],assignPublicIp=ENABLED}" \
    --load-balancers "targetGroupArn=$TG_ARN,containerName=$CONTAINER,containerPort=3000" \
    --health-check-grace-period-seconds 30 \
    --deployment-configuration "deploymentCircuitBreaker={enable=true,rollback=true},maximumPercent=200,minimumHealthyPercent=100" \
    --tags "key=exam-token,value=$EXAM_TOKEN" --propagate-tags SERVICE \
    --query 'service.serviceArn' --output text || die "create-service failed"
else
  echo "service already ACTIVE; not recreating"
fi
echo "waiting for the service to be stable (tasks running, targets healthy; up to 10 minutes)..."
aws ecs wait services-stable --cluster "$CLUSTER" --services "$SERVICE" \
  || echo "WARNING: not stable yet -- the listings below show why"

aws ecs describe-services --cluster "$CLUSTER" --services "$SERVICE" \
  --query 'services[0].{service:serviceName,status:status,taskDefinition:taskDefinition,desired:desiredCount,running:runningCount,pending:pendingCount,launchType:launchType,grace:healthCheckGracePeriodSeconds,circuitBreaker:deploymentConfiguration.deploymentCircuitBreaker,targetGroup:loadBalancers[0].targetGroupArn,publicIp:networkConfiguration.awsvpcConfiguration.assignPublicIp}' \
  --output json
echo "--- last service events"
aws ecs describe-services --cluster "$CLUSTER" --services "$SERVICE" \
  --query 'services[0].events[:6].[createdAt,message]' --output text

# =============================================================================
step "5. which task is which -- task id, private IP, health"
TASKS=$(aws ecs list-tasks --cluster "$CLUSTER" --service-name "$SERVICE" \
  --desired-status RUNNING --query 'taskArns' --output text)
[ -n "$TASKS" ] || die "no running tasks"
aws ecs describe-tasks --cluster "$CLUSTER" --tasks $TASKS \
  --query "tasks[].{task:taskArn,az:availabilityZone,privateIp:attachments[0].details[?name=='privateIPv4Address']|[0].value,last:lastStatus,health:healthStatus,revision:taskDefinitionArn}" \
  --output table
echo "--- the same IPs as the load balancer sees them"
aws elbv2 describe-target-health --target-group-arn "$TG_ARN" \
  --query 'TargetHealthDescriptions[].{ip:Target.Id,port:Target.Port,az:Target.AvailabilityZone,state:TargetHealth.State,reason:TargetHealth.Reason}' \
  --output table

# =============================================================================
step "6. THE DELIVERABLE -- repeated requests through the ALB reach different tasks"
echo "ALB: http://$DNS"
# A brand-new ALB name can take a minute or two to resolve.
for i in $(seq 1 30); do
  code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 "http://$DNS/readyz") || code=000
  [ "$code" = "200" ] && break
  echo "  /readyz via ALB -> $code, retrying in 10 s"; sleep 10
done
[ "$code" = "200" ] || die "ALB never returned 200 on /readyz"

# One curl per request = a new TCP connection each time, so the ALB makes a
# fresh routing decision for every line (it balances per request anyway).
# /healthz returns os.hostname(), which on Fargate is the task's private DNS
# name -- ip-172-31-x-x -- so it matches a privateIp in the table above.
hosts=()
for i in $(seq -w 1 12); do
  body=$(curl -s --max-time 5 "http://$DNS/healthz")
  echo "request $i  $body"
  hosts+=("$(printf '%s' "$body" | sed -n 's/.*"host":"\([^"]*\)".*/\1/p')")
done
echo
echo "--- responses per task"
printf '%s\n' "${hosts[@]}" | sort | uniq -c
distinct=$(printf '%s\n' "${hosts[@]}" | sort -u | grep -c .)
stamp
if [ "$distinct" -ge 2 ]; then
  echo "=== $distinct different tasks served 12 requests through one ALB DNS name ==="
else
  echo "=== WARNING: only $distinct task answered -- not yet evidence for task 51 ==="
fi
echo "ALB DNS name: $DNS"
