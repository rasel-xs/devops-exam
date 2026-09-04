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
  "health")    exec curl -sf --connect-timeout 3 --max-time 5 http://127.0.0.1:3140/healthz ;;
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
#
# The {{if}} guard is not defensive noise. `docker service inspect` omits
# UpdateStatus ENTIRELY -- not empty, absent -- on a service that has never been
# updated, and Swarm also clears it when an update turns out to be a no-op.
# A bare {{.UpdateStatus.State}} then fails with
# "map has no entry for key UpdateStatus" and kills the script under set -e.
# CI never hits it because every run carries a fresh tag; re-running the same
# tag by hand does, which is how it was found.
upd_state() {
  docker service inspect "$SERVICE" --format '{{if .UpdateStatus}}{{.UpdateStatus.State}}{{else}}none{{end}}'
}
upd_started() {
  docker service inspect "$SERVICE" --format '{{if .UpdateStatus}}{{.UpdateStatus.StartedAt}}{{else}}none{{end}}'
}

prev_started=$(upd_started)

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
  state=$(upd_state)
  started=$(upd_started)
  reps=$(docker service ls --filter "name=$SERVICE" --format '{{.Replicas}}')
  want=${reps#*/}
  on_new=$(docker service ps "$SERVICE" --filter desired-state=running \
             --format '{{.Image}}' | grep -c ":${tag}\$" || true)
  echo "  [$i] state=$state  replicas=$reps  tasks_on_${tag}=$on_new/$want"

  # A rollback is the one thing task-counting cannot see: the tasks go back to
  # the OLD image and the count simply never rises. Check it first.
  case "$state" in
    rollback_started|rollback_completed|rollback_paused|paused)
      echo "ERROR: the update did not succeed -- state=$state" >&2
      docker service ps "$SERVICE" --no-trunc >&2
      exit 1 ;;
  esac

  # Otherwise the authority is the task count, not Swarm's opinion of itself --
  # B4 task 38 phase B had Swarm reporting "update completed" for a service
  # answering 500 to every request. "none" is the legitimate no-op case: the
  # service already runs this tag and there was nothing to roll.
  if [ "$on_new" = "$want" ]; then
    if [ "$state" = "none" ]; then
      echo "  (no update was needed -- already on $tag)"
      converged=yes; break
    fi
    if [ "$state" = "completed" ] && [ "$started" != "$prev_started" ]; then
      converged=yes; break
    fi
  fi
  sleep 5
done

if [ "$converged" != "yes" ]; then
  echo "ERROR: did not converge on $tag within 6 minutes" >&2
  docker service ps "$SERVICE" --no-trunc >&2
  exit 1
fi

echo "--- tasks after the update ---"
docker service ps "$SERVICE" --no-trunc | head -10

# The update reaching "completed" only means Swarm accepted and rolled it out.
# B4 task 38 phase B is the reason this check exists: Swarm reported
# "update completed" for a service answering 500 to every request.
# 127.0.0.1 and not "localhost", with explicit timeouts. CI run #11 sat on
# "health poll 1/30" for eight minutes: "localhost" resolves to ::1 first, the
# published port is IPv4, and a curl with no --connect-timeout waits out the
# full TCP timeout rather than failing fast. B2 task 28 measured exactly this --
# a dropped packet gives no RST, so the client just waits. Every B4 script used
# 127.0.0.1 and --max-time for that reason; this one had drifted.
echo "--- verifying the deployed version actually answers ---"
for i in $(seq 1 30); do
  # The echo is not decoration. The first CI deploy died with "Broken pipe"
  # during this loop: it produced no output for a minute and the SSH transport
  # went away. Keepalives on the client are the real fix; this makes the
  # symptom visible in the log if it happens again.
  echo "  health poll $i/30"
  if curl -sf --connect-timeout 3 --max-time 5 http://127.0.0.1:3140/healthz | grep -q '"status":"ok"'; then
    echo "live and healthy:"; curl -s --connect-timeout 3 --max-time 5 http://127.0.0.1:3140/healthz; echo
    exit 0
  fi
  sleep 2
done

echo "ERROR: service did not become healthy after the update" >&2
docker service ps "$SERVICE" --no-trunc >&2
exit 1
