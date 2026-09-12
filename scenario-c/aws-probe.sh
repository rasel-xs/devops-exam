#!/usr/bin/env bash
# Scenario C, step 0 -- what can this identity actually do?
#
# The account was provided to me as an IAM user; I do not have root. That
# matters before any resource is created, because several Scenario C tasks need
# permissions an IAM user is not normally given (IAM writes for task 47, policy
# simulation for 48, Billing/Cost Explorer for 63).
#
# This probes by CALLING each API rather than by reading policies, because
# reading a policy needs its own permission and because an explicit Deny, an
# SCP, or a permissions boundary will not show up in the attached-policy list
# at all. An API call is the only answer that counts.
#
# Every probe here is READ-ONLY. Nothing is created, modified or deleted.
set -uo pipefail

TODAY=$(date -u +%Y-%m-%d)
MONTH_START=$(date -u +%Y-%m-01)

probe() {
  local label="$1" cmd="$2" out rc
  printf '  %-40s ' "$label"
  out=$(eval "$cmd" 2>&1); rc=$?
  if [ $rc -eq 0 ]; then
    echo "ALLOWED"
    return
  fi
  case "$out" in
    *AccessDenied*|*"not authorized"*|*UnauthorizedOperation*|*AuthorizationError*)
      echo "DENIED" ;;
    *ExpiredToken*|*InvalidClientTokenId*|*SignatureDoesNotMatch*)
      echo "BAD CREDENTIALS" ;;
    *"could not be found"*|*NotFound*|*NoSuchEntity*)
      # The call was permitted; there is simply nothing there yet.
      echo "ALLOWED (empty)" ;;
    *)
      echo "OTHER: $(printf '%s' "$out" | head -1 | cut -c1-70)" ;;
  esac
}

echo "EXAM_TOKEN: ${EXAM_TOKEN:-unset} | $(date)"
echo
echo "=== who am I ==="
aws sts get-caller-identity 2>&1
echo
echo "region: $(aws configure get region 2>/dev/null || echo '(not set)')"
echo

echo "=== what Scenario C needs ==="
probe "ecr   (task 49: push image)"        "aws ecr describe-repositories --max-items 1"
probe "ecs   (tasks 50-53)"                "aws ecs list-clusters"
probe "elbv2 (task 51: load balancer)"     "aws elbv2 describe-load-balancers --page-size 1"
probe "logs  (task 50: CloudWatch)"        "aws logs describe-log-groups --limit 1"
probe "cloudwatch (task 52: CPU graph)"    "aws cloudwatch list-metrics --namespace AWS/ECS --max-items 1"
probe "app-autoscaling (task 52)"          "aws application-autoscaling describe-scalable-targets --service-namespace ecs"
probe "s3    (tasks 55-58)"                "aws s3api list-buckets"
probe "ec2   (VPC lookup, task 63 listing)" "aws ec2 describe-vpcs --max-items 1"
echo
echo "=== the ones an IAM user often cannot do ==="
probe "iam list-users (task 47)"           "aws iam list-users --max-items 1"
probe "iam get-user   (task 47)"           "aws iam get-user"
probe "iam simulate   (task 48)"           "aws iam simulate-principal-policy --policy-source-arn \"\$(aws sts get-caller-identity --query Arn --output text)\" --action-names s3:ListAllMyBuckets"
probe "iam create-policy (task 47, DRY)"   "aws iam create-policy --policy-name abdur-probe-dryrun --policy-document '{\"Version\":\"2012-10-17\",\"Statement\":[]}' --no-cli-pager"
probe "cost-explorer (task 63)"            "aws ce get-cost-and-usage --time-period Start=$MONTH_START,End=$TODAY --granularity MONTHLY --metrics UnblendedCost"
probe "budgets (billing alarm)"            "aws budgets describe-budgets --account-id \"\$(aws sts get-caller-identity --query Account --output text)\""
echo
echo "NOTE: the iam create-policy probe above sends an EMPTY statement list, so"
echo "      AWS rejects it as MalformedPolicyDocument if I am allowed and as"
echo "      AccessDenied if I am not. 'OTHER: ...Malformed...' therefore means"
echo "      ALLOWED. Nothing is created either way."
