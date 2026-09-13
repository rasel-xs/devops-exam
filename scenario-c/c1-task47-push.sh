#!/usr/bin/env bash
# Scenario C tasks 47 + 49 -- push to ECR as abdur-exam-deployer, then prove the
# same identity is denied everything else.
#
# Run on the VPS:
#   export EXAM_TOKEN=root-vmi3536696-1788282556-1536d427
#   bash scenario-c/c1-task47-push.sh 2>&1 | tee scenario-c/evidence/c1-task47-push.txt
# and only paste the key when the prompt appears.
#
# CREDENTIAL HANDLING -- the VPS is shared and every student on it is root, so
# nothing secret is allowed to touch disk:
#
#   * The access key is typed at a prompt (the secret is not echoed) and held
#     only in this script's environment. Never written to ~/.aws; gone on exit.
#     `aws configure` would have left it in plain text in /root/.aws/credentials.
#
#   * `docker login` normally stores the registry token in
#     /root/.docker/config.json -- the same shared file. DOCKER_CONFIG points it
#     at a private temporary directory instead, removed on exit. The ECR token is
#     valid for 12 hours.
#
#   * The access key itself is deleted in the console straight after this run.
#
# RUN 1 OF THIS SCRIPT FAILED IN A WAY WORTH DESIGNING AGAINST
# (evidence/c1-task47-push-run1-paste-ahead.txt). The command block was pasted
# twice; the script started, and the still-buffered pasted lines were consumed by
# its own prompts, so the "access key" was `cd /root/abdur-exam`. Every AWS call
# then failed with IncompleteSignature / AuthorizationHeaderMalformed -- and the
# old script printed those five failures under a heading reading DENIED. Read
# quickly, that transcript "proved" task 47. It proved nothing: AWS rejected the
# requests before looking up any identity. Hence the guards below:
#   1. typeahead is drained before each prompt, and prompts read /dev/tty;
#   2. the key ID and secret are format-checked before use;
#   3. the script stops unless sts confirms the identity is abdur-exam-deployer;
#   4. a "denied" test only counts if the error is actually an authorization
#      denial -- anything else is reported as NOT A DENIAL.
set -uo pipefail

REGION=eu-north-1
ACCOUNT=750069566598
REPO=abdur-notes-api
REGISTRY="$ACCOUNT.dkr.ecr.$REGION.amazonaws.com"
SERVICE=abdur_notes_app
EXPECTED_USER_ARN="arn:aws:iam::$ACCOUNT:user/abdur-exam-deployer"

# The VPS root account is shared, and the brief's token recipe appends to the
# shared ~/.bashrc -- so whichever student generated a token last "wins". Every
# Scenario A and B transcript in this repo carries this one.
MY_EXAM_TOKEN=root-vmi3536696-1788282556-1536d427
if [ "${EXAM_TOKEN:-}" != "$MY_EXAM_TOKEN" ]; then
  echo "ERROR: EXAM_TOKEN in this shell is '${EXAM_TOKEN:-unset}'," >&2
  echo "       not the token used for every other transcript in this repo." >&2
  echo "       The shared /root/.bashrc has probably been appended to by someone else." >&2
  echo "       Run:  export EXAM_TOKEN=$MY_EXAM_TOKEN" >&2
  exit 1
fi

stamp() { echo; echo "EXAM_TOKEN: $EXAM_TOKEN | $(date)"; }
die()   { echo; echo "STOPPED: $*" >&2; exit 1; }

# Throw away anything already sitting in the terminal's input buffer, so a
# multi-line paste cannot answer a prompt that has not been shown yet.
drain_typeahead() { while read -r -t 0.2 _ </dev/tty; do :; done; }

# --- the image to push: whatever the B4 swarm service is actually running ----
SRC=$(docker service inspect "$SERVICE" \
        --format '{{.Spec.TaskTemplate.ContainerSpec.Image}}' 2>/dev/null)
SRC=${SRC%@*}
TAG=${SRC##*:}
[ -n "$SRC" ] && docker image inspect "$SRC" >/dev/null 2>&1 \
  || die "could not find the running image locally (got '$SRC')"
echo "source image: $SRC"
echo "will push as: $REGISTRY/$REPO:$TAG"

# --- credentials, memory only ------------------------------------------------
echo
drain_typeahead
read -rp  "AWS_ACCESS_KEY_ID for abdur-exam-deployer: " AWS_ACCESS_KEY_ID </dev/tty
[[ "$AWS_ACCESS_KEY_ID" =~ ^(AKIA|ASIA)[A-Z0-9]{16}$ ]] \
  || die "that is not an access key ID (expected AKIA + 16 characters). Did a pasted command land in the prompt?"
drain_typeahead
read -rsp "AWS_SECRET_ACCESS_KEY (not shown): " AWS_SECRET_ACCESS_KEY </dev/tty; echo
[[ "$AWS_SECRET_ACCESS_KEY" =~ ^[A-Za-z0-9/+]{40}$ ]] \
  || die "that is not a secret access key (expected 40 characters, no spaces)."

export AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_DEFAULT_REGION=$REGION
export AWS_CONFIG_FILE=/dev/null AWS_SHARED_CREDENTIALS_FILE=/dev/null
DOCKER_CONFIG=$(mktemp -d); export DOCKER_CONFIG
trap 'rm -rf "$DOCKER_CONFIG"; unset AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY' EXIT

# =============================================================================
stamp
echo "=== 1. who am I -- must be abdur-exam-deployer, not rasel ==="
aws sts get-caller-identity --output table || die "sts get-caller-identity failed; nothing below would mean anything."
ARN=$(aws sts get-caller-identity --query Arn --output text)
[ "$ARN" = "$EXPECTED_USER_ARN" ] \
  || die "running as $ARN, not $EXPECTED_USER_ARN. A denial test under the wrong identity proves nothing."
echo "identity confirmed: $ARN"

# =============================================================================
stamp
echo "=== 2. ALLOWED: log in to ECR and push ==="
aws ecr get-login-password --region "$REGION" \
  | docker login --username AWS --password-stdin "$REGISTRY" \
  || die "ECR login failed"
docker tag "$SRC" "$REGISTRY/$REPO:$TAG"
docker push "$REGISTRY/$REPO:$TAG" || die "push failed"
echo "push exit code: 0"

# =============================================================================
stamp
echo "=== 3. DENIED: everything outside the policy ==="
not_denials=0
denied() {
  local label="$1"; shift
  local out rc
  echo
  echo "--- $label"
  echo "\$ $*"
  out=$("$@" 2>&1); rc=$?
  printf '%s\n' "$out" | head -4
  if [ $rc -eq 0 ]; then
    echo ">>> ALLOWED -- this should have been denied"; not_denials=$((not_denials+1))
  elif printf '%s' "$out" | grep -qE 'AccessDenied|not authorized|UnauthorizedOperation|AuthorizationError'; then
    echo ">>> DENIED, as intended (exit $rc)"
  else
    echo ">>> NOT A DENIAL -- failed for some other reason (exit $rc)"; not_denials=$((not_denials+1))
  fi
}
denied "S3 -- the brief's example"                      aws s3 ls
denied "ECS read -- policy grants UpdateService only"    aws ecs list-clusters
denied "ECR list -- not in the policy"                   aws ecr describe-repositories
denied "ECR PULL -- BatchGetImage was deliberately removed" \
       aws ecr batch-get-image --repository-name "$REPO" --image-ids imageTag="$TAG"
denied "IAM -- must not be able to see, let alone widen, its own permissions" \
       aws iam list-attached-user-policies --user-name abdur-exam-deployer

stamp
if [ "$not_denials" -eq 0 ]; then
  echo "=== all 5 outside-policy calls were genuinely denied ==="
else
  echo "=== WARNING: $not_denials of 5 were NOT authorization denials -- do not use as evidence ==="
fi
echo "=== Now deactivate and delete this access key in the IAM console. ==="
