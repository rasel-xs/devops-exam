#!/usr/bin/env bash
# Seed the RDS database once, as a one-off Fargate task, for tasks 52 and C3.
#
#   bash c2-seed-rds.sh 2>&1 | tee evidence/c2-seed-rds.txt
#
# Why a task and not psql from here: the database is private (no public
# endpoint) and abdur-notes-db-sg admits 5432 only from abdur-notes-app-sg. A task
# in that security group is the only thing that can reach it -- the same path
# the service uses, with the password injected from Secrets Manager, so nobody
# handles it.
#
# seed.js TRUNCATEs tenants/notes/tags first. That is safe now: the tables were
# created empty by task 50's migration and nothing has written to them since.
set -uo pipefail
export AWS_REGION=eu-north-1 AWS_DEFAULT_REGION=eu-north-1 AWS_PAGER=""

EXAM_TOKEN=root-vmi3536696-1788282556-1536d427
EXPECTED_ARN="arn:aws:iam::750069566598:user/rasel"
CLUSTER=abdur-exam-cluster
TASKDEF=abdur-notes-api:1
VPC=vpc-064521cd395a04e1c
APP_SG=sg-0cdfa2df06a0ca703
LOG_GROUP=/ecs/abdur-notes-api

stamp() { echo; echo "EXAM_TOKEN: $EXAM_TOKEN | $(date)"; }
die()   { echo; echo "STOPPED: $*" >&2; exit 1; }

stamp
ARN=$(aws sts get-caller-identity --query Arn --output text) || die "sts failed (run: aws login)"
[ "$ARN" = "$EXPECTED_ARN" ] || die "running as $ARN"
echo "identity: $ARN"

SUBNETS_CSV=$(aws ec2 describe-subnets \
  --filters "Name=vpc-id,Values=$VPC" "Name=default-for-az,Values=true" \
  --query 'Subnets[].SubnetId' --output text | tr '\t' ',')

# The task definition's container health check probes /healthz, which nothing
# serves during a seed. It only becomes UNHEALTHY after start period 15 s + 3 x
# 10 s, and a standalone task (no service) is not replaced for it; the seed
# itself takes seconds.
stamp
echo "=== one-off task: node db/seed.js ==="
TASK_ARN=$(aws ecs run-task --cluster "$CLUSTER" --task-definition "$TASKDEF" \
  --launch-type FARGATE --count 1 --started-by abdur-seed \
  --network-configuration "awsvpcConfiguration={subnets=[$SUBNETS_CSV],securityGroups=[$APP_SG],assignPublicIp=ENABLED}" \
  --overrides '{"containerOverrides":[{"name":"notes-api","command":["node","db/seed.js"]}]}' \
  --tags "key=exam-token,value=$EXAM_TOKEN" \
  --query 'tasks[0].taskArn' --output text) || die "run-task failed"
[ -n "$TASK_ARN" ] && [ "$TASK_ARN" != "None" ] || die "no task started"
TASK_ID=${TASK_ARN##*/}
echo "task: $TASK_ID"

echo "waiting for it to finish..."
aws ecs wait tasks-stopped --cluster "$CLUSTER" --tasks "$TASK_ARN" || die "did not stop within the waiter's 10 minutes"
aws ecs describe-tasks --cluster "$CLUSTER" --tasks "$TASK_ARN" \
  --query 'tasks[0].{stoppedReason:stoppedReason,exitCode:containers[0].exitCode,started:startedAt,stopped:stoppedAt}' \
  --output json
EXIT=$(aws ecs describe-tasks --cluster "$CLUSTER" --tasks "$TASK_ARN" \
  --query 'tasks[0].containers[0].exitCode' --output text)

stamp
echo "=== its log stream: notes-api/notes-api/$TASK_ID ==="
aws logs get-log-events --log-group-name "$LOG_GROUP" \
  --log-stream-name "notes-api/notes-api/$TASK_ID" --start-from-head \
  --query 'events[].message' --output text | tr '\t' '\n'

stamp
[ "$EXIT" = "0" ] && echo "=== seed finished, exit code 0 ===" || die "seed exit code $EXIT"
