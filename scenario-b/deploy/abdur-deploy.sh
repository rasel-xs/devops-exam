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
#
# --detach is deliberate. Without it, `docker service update` blocks on its own
# progress display, and CI run #10 sat on "overall progress: 0 out of 3 tasks"
# for more than eight minutes while the service had in fact converged in 93
# seconds (UpdateStatus said "completed", all three tasks healthy on the new
# image). The cause is a leftover task from the task-39 reservation experiment
# that has an empty NodeID -- the progress writer resolves tasks to nodes and
# never marks that slot done. Rather than depend on a display, this polls the
# two things that are actually authoritative: UpdateStatus.State, and how many
# running tasks carry the requested tag.
# Remember which update we are replacing. Without this the poll below can read
# the PREVIOUS update's "completed" in the first second and declare success
# before Swarm has even started -- a bug I put in this script and caught by
# reading it, not by running it.
prev_started=$(docker service inspect "$SERVICE" --format '{{.UpdateStatus.StartedAt}}')

docker service update --detach \
  --image "$IMAGE" \
  --update-order start-first \
  --update-parallelism 1 \
  --update-delay 10s \
  --update-monitor 20s \
  --update-failure-action rollback \
  --with-registry-auth \
  "$SERVICE" > /dev/null

echo "--- waiting for convergence ---"
converged=no
i=0
while [ "$i" -lt 72 ]; do
  i=$((i + 1))
  state=$(docker service inspect "$SERVICE" --format '{{.UpdateStatus.State}}')
  started=$(docker service inspect "$SERVICE" --format '{{.UpdateStatus.StartedAt}}')
  reps=$(docker service ls --filter "name=$SERVICE" --format '{{.Replicas}}')
  want=${reps#*/}
  on_new=$(docker service ps "$SERVICE" --filter desired-state=running \
             --format '{{.Image}}' | grep -c ":${tag}\$" || true)
  echo "  [$i] state=$state  replicas=$reps  tasks_on_${tag}=$on_new/$want"

  # Three conditions, because any one of them alone has a way of lying:
  #   - a stale "completed" belongs to the previous update  -> compare StartedAt
  #   - "completed" is Swarm's opinion of its own rollout   -> count the tasks
  #   - counting tasks alone cannot see a rollback          -> read the state
  if [ "$started" != "$prev_started" ]; then
    case "$state" in
      completed)
        [ "$on_new" = "$want" ] && { converged=yes; break; } ;;
      rollback_started|rollback_completed|rollback_paused|paused)
        echo "ERROR: the update did not succeed -- state=$state" >&2
        docker service ps "$SERVICE" --no-trunc >&2
        exit 1 ;;
    esac
  fi
  sleep 5
done

if [ "$converged" != "yes" ]; then
  echo "ERROR: update did not reach 'completed' within 6 minutes" >&2
  docker service ps "$SERVICE" --no-trunc >&2
  exit 1
fi

echo "--- tasks after the update ---"
docker service ps "$SERVICE" --no-trunc | head -10

# The update reaching "completed" only means Swarm accepted and rolled it out.
# B4 task 38 phase B is the reason this check exists: Swarm reported
# "update completed" for a service answering 500 to every request.
echo "--- verifying the deployed version actually answers ---"
for i in $(seq 1 30); do
  # The echo is not decoration. The first CI deploy died with "Broken pipe"
  # during this loop: it produced no output for a minute and the SSH transport
  # went away. Keepalives on the client are the real fix; this makes the
  # symptom visible in the log if it happens again.
  echo "  health poll $i/30"
  if curl -sf http://localhost:3140/healthz | grep -q '"status":"ok"'; then
    echo "live and healthy:"; curl -s http://localhost:3140/healthz; echo
    exit 0
  fi
  sleep 2
done

echo "ERROR: service did not become healthy after the update" >&2
docker service ps "$SERVICE" --no-trunc >&2
exit 1
