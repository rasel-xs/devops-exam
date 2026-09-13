#!/usr/bin/env bash
# Scenario C tasks 47 + 49 -- push to ECR as abdur-exam-deployer, then prove the
# same identity is denied everything else.
#
# Run on the VPS:   bash scenario-c/c1-task47-push.sh 2>&1 | tee scenario-c/evidence/c1-task47-push.txt
#
# CREDENTIAL HANDLING -- the VPS is shared and every student on it is root, so
# nothing secret is allowed to touch disk:
#
#   * The access key is typed in at a prompt (the secret is not echoed) and held
#     only in this script's environment. It is never written to ~/.aws, and it
#     is gone when the script exits. `aws configure` would have written it in
#     plain text to /root/.aws/credentials for anyone to cat.
#
#   * `docker login` normally stores the registry token in
#     /root/.docker/config.json -- the same shared file. DOCKER_CONFIG points it
#     at a private temporary directory instead, removed on exit. The ECR token
#     is valid for 12 hours, so leaving it behind would hand another student
#     push access for the rest of the day.
#
#   * The access key itself is deleted in the console straight after this run.
#
# Even if all of that failed, the key can do exactly three things: fetch an ECR
# login token, push to abdur-notes-api, and update abdur-notes-svc. That is what
# task 47 is for.
set -uo pipefail

REGION=eu-north-1
ACCOUNT=750069566598
REPO=abdur-notes-api
REGISTRY="$ACCOUNT.dkr.ecr.$REGION.amazonaws.com"
SERVICE=abdur_notes_app

stamp() { echo; echo "EXAM_TOKEN: ${EXAM_TOKEN:-unset} | $(date)"; }

# --- the image to push: whatever the B4 swarm service is actually running ----
SRC=$(docker service inspect "$SERVICE" \
        --format '{{.Spec.TaskTemplate.ContainerSpec.Image}}' 2>/dev/null)
SRC=${SRC%@*}                     # drop the @sha256 digest pin
TAG=${SRC##*:}
if [ -z "$SRC" ] || ! docker image inspect "$SRC" >/dev/null 2>&1; then
  echo "ERROR: could not find the running image locally (got '$SRC')" >&2
  exit 1
fi
echo "source image: $SRC"
echo "will push as: $REGISTRY/$REPO:$TAG"

# --- credentials, memory only ------------------------------------------------
echo
read -rp  "AWS_ACCESS_KEY_ID for abdur-exam-deployer: " AWS_ACCESS_KEY_ID
read -rsp "AWS_SECRET_ACCESS_KEY (not shown): " AWS_SECRET_ACCESS_KEY; echo
export AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_DEFAULT_REGION=$REGION
# Make sure nothing on disk can override the typed-in identity.
export AWS_CONFIG_FILE=/dev/null AWS_SHARED_CREDENTIALS_FILE=/dev/null

DOCKER_CONFIG=$(mktemp -d)
export DOCKER_CONFIG
trap 'rm -rf "$DOCKER_CONFIG"; unset AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY' EXIT

# =============================================================================
stamp
echo "=== 1. who am I -- must be abdur-exam-deployer, not rasel ==="
aws sts get-caller-identity --output table

# =============================================================================
stamp
echo "=== 2. ALLOWED: log in to ECR and push ==="
aws ecr get-login-password --region "$REGION" \
  | docker login --username AWS --password-stdin "$REGISTRY"
docker tag "$SRC" "$REGISTRY/$REPO:$TAG"
docker push "$REGISTRY/$REPO:$TAG"
echo "push exit code: $?"

# =============================================================================
stamp
echo "=== 3. DENIED: everything outside the policy ==="
denied() {
  local label="$1"; shift
  echo
  echo "--- $label"
  echo "\$ $*"
  "$@" 2>&1 | head -4
  echo "exit code: ${PIPESTATUS[0]}"
}
denied "S3 -- the brief's example"                      aws s3 ls
denied "ECS read -- policy grants UpdateService only"    aws ecs list-clusters
denied "ECR list -- not in the policy"                   aws ecr describe-repositories
denied "ECR PULL -- BatchGetImage was deliberately removed" \
       aws ecr batch-get-image --repository-name "$REPO" --image-ids imageTag="$TAG"
denied "IAM -- must not be able to see, let alone widen, its own permissions" \
       aws iam list-attached-user-policies --user-name abdur-exam-deployer

stamp
echo "=== done. Now delete this access key in the IAM console. ==="
