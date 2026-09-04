#!/bin/sh
# Forced command for the GitHub Actions deploy key (B5 task 44).
#
# Installed in /root/.ssh/authorized_keys as:
#
#   command="/root/abdur-deploy.sh",no-port-forwarding,no-agent-forwarding,
#   no-X11-forwarding,no-pty ssh-ed25519 AAAA... github-actions-abdur
#
# WHY THIS EXISTS. The deploy needs a long-lived SSH private key in a GitHub
# secret, and this VPS is shared with other students while the account is root.
# An unrestricted key in a repository secret means: anyone who can change a
# workflow file, or read the secret through a compromised action, gets root on a
# machine that is not only mine. A forced command removes the client's ability
# to choose WHAT runs. It can only choose the one argument below, and that
# argument is validated before it is used.
#
# This does not make the key harmless -- it makes the blast radius "can deploy a
# tag that exists in my registry" instead of "root shell". That is the honest
# claim.
set -eu

SERVICE=abdur_notes_app
IMAGE_REPO=ghcr.io/rasel-xs/notes-api

cmd="${SSH_ORIGINAL_COMMAND:-}"

case "$cmd" in
  "deploy "*)  tag="${cmd#deploy }" ;;
  "status")    exec docker service ps "$SERVICE" --no-trunc ;;
  "health")    exec curl -sf http://localhost:3140/healthz ;;
  *)
    echo "refused: this key may only run 'deploy <tag>', 'status' or 'health'" >&2
    echo "received: $cmd" >&2
    exit 1 ;;
esac

# Tag allow-list. Without this, `deploy ../../something` or a tag pointing at an
# attacker-controlled image would be accepted. Only the two shapes the CI
# actually produces are permitted.
case "$tag" in
  v1.0.[0-9]*)                    : ;;
  sha-[0-9a-f][0-9a-f]*)          : ;;
  *) echo "refused: tag '$tag' is not v1.0.<n> or sha-<hex>" >&2; exit 1 ;;
esac
case "$tag" in *[!A-Za-z0-9.-]*) echo "refused: bad characters in tag" >&2; exit 1 ;; esac

IMAGE="$IMAGE_REPO:$tag"
echo "deploying $IMAGE to $SERVICE"

# Rolling in-place update, NOT rm + create. The running tasks keep serving until
# the replacements are healthy, and a task that never becomes healthy triggers
# an automatic revert -- measured in B4 task 38 at 33s with zero failed client
# requests.
docker service update \
  --image "$IMAGE" \
  --update-order start-first \
  --update-parallelism 1 \
  --update-delay 10s \
  --update-monitor 20s \
  --update-failure-action rollback \
  --with-registry-auth \
  "$SERVICE"

echo "--- tasks after the update ---"
docker service ps "$SERVICE" --no-trunc | head -10

# The update command returning 0 only means Swarm accepted the instruction.
# B4 task 38 phase B is the reason this check exists: Swarm reported
# "update completed" for a service answering 500 to every request.
echo "--- verifying the deployed version actually answers ---"
for i in $(seq 1 30); do
  if curl -sf http://localhost:3140/healthz | grep -q '"status":"ok"'; then
    echo "live and healthy:"; curl -s http://localhost:3140/healthz; echo
    exit 0
  fi
  sleep 2
done

echo "ERROR: service did not become healthy after the update" >&2
docker service ps "$SERVICE" --no-trunc >&2
exit 1
