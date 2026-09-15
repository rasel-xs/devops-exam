#!/usr/bin/env bash
# Scenario C task 63 -- delete everything I created in the shared AWS account.
#
#   bash c5-task63-cleanup.sh 2>&1 | tee evidence/c5-task63-cleanup.txt
#
# SHARED ACCOUNT RULES, enforced below:
#   * only resources whose name starts with "abdur" are touched -- the inventory
#     taken just before this found another student's S3 bucket
#     (ashik-notes-attachments-...) and the account's GitHub OIDC provider, which
#     another student created and my role only used; neither is deleted
#   * order follows dependencies: nothing is deleted while something still uses it
#   * every deletion is waited on and then checked, not assumed
set -uo pipefail
export AWS_REGION=eu-north-1 AWS_DEFAULT_REGION=eu-north-1 AWS_PAGER=""

EXAM_TOKEN=root-vmi3536696-1788282556-1536d427
EXPECTED_ARN="arn:aws:iam::750069566598:user/rasel"
CLUSTER=abdur-exam-cluster
SERVICE=abdur-notes-svc
ALB=abdur-notes-alb
TG=abdur-notes-tg
DB=abdur-notes-db
REPO=abdur-notes-api
BUCKET=abdur-notes-750069566598
LOGS=/ecs/abdur-notes-api
SGS="abdur-notes-alb-sg abdur-notes-app-sg abdur-notes-db-sg"
ROLES="abdur-github-actions-ecs-deploy abdur-ecs-task-role abdur-ecs-task-execution-role"
USER_NAME=abdur-exam-deployer

stamp() { echo; echo "EXAM_TOKEN: $EXAM_TOKEN | $(date)"; }
step()  { stamp; echo "=== $* ==="; }
die()   { echo; echo "STOPPED: $*" >&2; exit 1; }
mine()  { case "$1" in abdur*|/ecs/abdur*|service/abdur*) return 0 ;; *) die "refusing to touch '$1' -- not an abdur resource" ;; esac; }

ARN=$(aws sts get-caller-identity --query Arn --output text) || die "sts failed (run: aws login)"
[ "$ARN" = "$EXPECTED_ARN" ] || die "running as $ARN"

# =============================================================================
step "1. autoscaling: policy, scalable target (target tracking deletes its alarms)"
mine "service/$CLUSTER/$SERVICE"
aws application-autoscaling delete-scaling-policy --service-namespace ecs --scalable-dimension ecs:service:DesiredCount \
  --resource-id "service/$CLUSTER/$SERVICE" --policy-name abdur-notes-cpu50 2>&1 | tail -1
aws application-autoscaling deregister-scalable-target --service-namespace ecs --scalable-dimension ecs:service:DesiredCount \
  --resource-id "service/$CLUSTER/$SERVICE" 2>&1 | tail -1
echo "alarms left: $(aws cloudwatch describe-alarms --alarm-name-prefix "TargetTracking-service/$CLUSTER/" --query 'length(MetricAlarms)' --output text)"

# =============================================================================
step "2. ECS service: scale to 0, delete, wait until INACTIVE"
mine "$SERVICE"; mine "$CLUSTER"
aws ecs update-service --cluster "$CLUSTER" --service "$SERVICE" --desired-count 0 --query 'service.desiredCount' --output text 2>&1 | tail -1
aws ecs delete-service --cluster "$CLUSTER" --service "$SERVICE" --force --query 'service.status' --output text 2>&1 | tail -1
aws ecs wait services-inactive --cluster "$CLUSTER" --services "$SERVICE" && echo "service INACTIVE"
echo "running tasks left: $(aws ecs list-tasks --cluster "$CLUSTER" --query 'length(taskArns)' --output text)"

# =============================================================================
step "3. load balancer, listener, target group"
mine "$ALB"; mine "$TG"
ALB_ARN=$(aws elbv2 describe-load-balancers --names "$ALB" --query 'LoadBalancers[0].LoadBalancerArn' --output text 2>/dev/null)
if [ -n "$ALB_ARN" ] && [ "$ALB_ARN" != None ]; then
  aws elbv2 delete-load-balancer --load-balancer-arn "$ALB_ARN" && aws elbv2 wait load-balancers-deleted --load-balancer-arns "$ALB_ARN" && echo "ALB deleted (its listener with it)"
fi
TG_ARN=$(aws elbv2 describe-target-groups --names "$TG" --query 'TargetGroups[0].TargetGroupArn' --output text 2>/dev/null)
if [ -n "$TG_ARN" ] && [ "$TG_ARN" != None ]; then
  for i in $(seq 1 20); do aws elbv2 delete-target-group --target-group-arn "$TG_ARN" 2>/dev/null && { echo "target group deleted"; break; }; sleep 6; done
fi

# =============================================================================
step "4. RDS: no final snapshot, no retained automated backups (its managed secret goes with it)"
mine "$DB"
aws rds delete-db-instance --db-instance-identifier "$DB" --skip-final-snapshot --delete-automated-backups \
  --query 'DBInstance.[DBInstanceIdentifier,DBInstanceStatus]' --output text 2>&1 | tail -1
echo "waiting for the instance to be deleted (usually 5-10 minutes)..."
aws rds wait db-instance-deleted --db-instance-identifier "$DB" && echo "RDS instance deleted"
echo "secrets left: $(aws secretsmanager list-secrets --query "length(SecretList[?contains(Name,'4a1bc93e')])" --output text)"

# =============================================================================
step "5. task definitions: deregister, then delete"
TDS=$(aws ecs list-task-definitions --family-prefix abdur-notes-api --query 'taskDefinitionArns' --output text)
for td in $TDS; do aws ecs deregister-task-definition --task-definition "$td" --query 'taskDefinition.[family,revision,status]' --output text; done
INACTIVE=$(aws ecs list-task-definitions --family-prefix abdur-notes-api --status INACTIVE --query 'taskDefinitionArns' --output text)
[ -n "$INACTIVE" ] && aws ecs delete-task-definitions --task-definitions $INACTIVE --query 'taskDefinitions[].[family,revision,status]' --output text

# =============================================================================
step "6. ECS cluster (Container Insights goes with it)"
aws ecs delete-cluster --cluster "$CLUSTER" --query 'cluster.[clusterName,status]' --output text

# =============================================================================
step "7. security groups -- only once no network interface uses them"
for i in $(seq 1 30); do
  n=$(aws ec2 describe-network-interfaces --filters Name=group-name,Values='abdur-*' --query 'length(NetworkInterfaces)' --output text)
  [ "$n" = 0 ] && break
  echo "  $n network interfaces still attached, waiting..."; sleep 20
done
# the db SG is referenced by nothing; the app SG is referenced by the db SG's
# rule, the alb SG by the app SG's rule -- so delete in that order
for name in abdur-notes-db-sg abdur-notes-app-sg abdur-notes-alb-sg; do
  mine "$name"
  id=$(aws ec2 describe-security-groups --filters Name=group-name,Values="$name" --query 'SecurityGroups[0].GroupId' --output text)
  [ "$id" = None ] && { echo "$name already gone"; continue; }
  aws ec2 delete-security-group --group-id "$id" && echo "$name ($id) deleted"
done

# =============================================================================
step "8. ECR repository and every image in it"
mine "$REPO"
aws ecr delete-repository --repository-name "$REPO" --force --query 'repository.repositoryName' --output text 2>&1 | tail -1

# =============================================================================
step "9. S3 bucket: every object, then the bucket"
mine "$BUCKET"
aws s3 rm "s3://$BUCKET" --recursive | tail -3
aws s3api delete-bucket --bucket "$BUCKET" && echo "bucket deleted"

# =============================================================================
step "10. CloudWatch log group"
mine "$LOGS"
aws logs delete-log-group --log-group-name "$LOGS" && echo "log group deleted"

# =============================================================================
step "11. IAM roles -- inline and attached policies first"
for r in $ROLES; do
  mine "$r"
  for p in $(aws iam list-role-policies --role-name "$r" --query 'PolicyNames' --output text 2>/dev/null); do
    aws iam delete-role-policy --role-name "$r" --policy-name "$p" && echo "  $r: inline $p deleted"
  done
  for p in $(aws iam list-attached-role-policies --role-name "$r" --query 'AttachedPolicies[].PolicyArn' --output text 2>/dev/null); do
    aws iam detach-role-policy --role-name "$r" --policy-arn "$p" && echo "  $r: detached $p"
  done
  aws iam delete-role --role-name "$r" && echo "role $r deleted"
done

step "12. IAM user $USER_NAME and its customer-managed policy"
mine "$USER_NAME"
for k in $(aws iam list-access-keys --user-name "$USER_NAME" --query 'AccessKeyMetadata[].AccessKeyId' --output text); do
  aws iam delete-access-key --user-name "$USER_NAME" --access-key-id "$k" && echo "  access key deleted"
done
aws iam delete-login-profile --user-name "$USER_NAME" 2>/dev/null && echo "  console login removed"
for p in $(aws iam list-attached-user-policies --user-name "$USER_NAME" --query 'AttachedPolicies[].PolicyArn' --output text); do
  aws iam detach-user-policy --user-name "$USER_NAME" --policy-arn "$p" && echo "  detached $p"
done
for p in $(aws iam list-user-policies --user-name "$USER_NAME" --query 'PolicyNames' --output text); do
  aws iam delete-user-policy --user-name "$USER_NAME" --policy-name "$p"
done
aws iam delete-user --user-name "$USER_NAME" && echo "user $USER_NAME deleted"
for arn in $(aws iam list-policies --scope Local --query "Policies[?starts_with(PolicyName,'abdur')].Arn" --output text); do
  for v in $(aws iam list-policy-versions --policy-arn "$arn" --query 'Versions[?!IsDefaultVersion].VersionId' --output text); do
    aws iam delete-policy-version --policy-arn "$arn" --version-id "$v"
  done
  aws iam delete-policy --policy-arn "$arn" && echo "policy $arn deleted"
done

# =============================================================================
step "THE BRIEF'S CHECKS"
echo "\$ aws ecs list-clusters";                     aws ecs list-clusters
echo "\$ aws elbv2 describe-load-balancers";         aws elbv2 describe-load-balancers
echo "\$ aws s3 ls";                                 aws s3 ls
echo "\$ aws ec2 describe-instances --query 'Reservations[].Instances[?State.Name!=\`terminated\`].InstanceId'"
aws ec2 describe-instances --query 'Reservations[].Instances[?State.Name!=`terminated`].InstanceId'

step "AND MINE: anything named abdur left anywhere?"
printf '%-22s %s\n' "ECS clusters"    "$(aws ecs list-clusters --query "clusterArns[?contains(@,'abdur')]" --output text)"
printf '%-22s %s\n' "task definitions" "$(aws ecs list-task-definitions --family-prefix abdur --query 'taskDefinitionArns' --output text)"
printf '%-22s %s\n' "load balancers"  "$(aws elbv2 describe-load-balancers --query "LoadBalancers[?starts_with(LoadBalancerName,'abdur')].LoadBalancerName" --output text)"
printf '%-22s %s\n' "target groups"   "$(aws elbv2 describe-target-groups --query "TargetGroups[?starts_with(TargetGroupName,'abdur')].TargetGroupName" --output text)"
printf '%-22s %s\n' "RDS"             "$(aws rds describe-db-instances --query "DBInstances[?starts_with(DBInstanceIdentifier,'abdur')].DBInstanceIdentifier" --output text)"
printf '%-22s %s\n' "RDS secret"      "$(aws secretsmanager list-secrets --query "SecretList[?contains(Name,'4a1bc93e')].Name" --output text)"
printf '%-22s %s\n' "security groups" "$(aws ec2 describe-security-groups --filters Name=group-name,Values='abdur-*' --query 'SecurityGroups[].GroupName' --output text)"
printf '%-22s %s\n' "ECR"             "$(aws ecr describe-repositories --query "repositories[?starts_with(repositoryName,'abdur')].repositoryName" --output text)"
printf '%-22s %s\n' "S3"              "$(aws s3api list-buckets --query "Buckets[?starts_with(Name,'abdur')].Name" --output text)"
printf '%-22s %s\n' "log groups"      "$(aws logs describe-log-groups --log-group-name-prefix /ecs/abdur --query 'logGroups[].logGroupName' --output text)"
printf '%-22s %s\n' "IAM roles"       "$(aws iam list-roles --query "Roles[?starts_with(RoleName,'abdur')].RoleName" --output text)"
printf '%-22s %s\n' "IAM users"       "$(aws iam list-users --query "Users[?starts_with(UserName,'abdur')].UserName" --output text)"
printf '%-22s %s\n' "IAM policies"    "$(aws iam list-policies --scope Local --query "Policies[?starts_with(PolicyName,'abdur')].PolicyName" --output text)"
printf '%-22s %s\n' "alarms"          "$(aws cloudwatch describe-alarms --alarm-name-prefix TargetTracking-service/abdur --query 'MetricAlarms[].AlarmName' --output text)"
echo "(an empty column means nothing is left)"

stamp
echo "=== cleanup done ==="
