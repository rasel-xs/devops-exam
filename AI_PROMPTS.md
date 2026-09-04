# AI_PROMPTS.md

Log of where AI actually helped, where it was wrong, and what I had to change to
make the answer work on my machine.

> Marker's bar: pasting prompts without saying what went wrong = 2 marks.
> Full marks need at least 8 entries that show the gap between the generic
> answer and the real problem.

**9 entries.** Seven of them are cases where the answer I was given, or the
prediction I wrote from it, was **wrong**, and a measurement corrected it. Those
are the ones with any value: in each, the generic answer was the *typical* case
and the interesting behaviour lived in the difference between typical and mine.

| # | Where the generic answer broke |
| --- | --- |
| 1 | Every quantity in a generated repo is invented, however sensible it looks |
| 2 | A famous bash gotcha that was not the bug — I changed two things at once |
| 3 | Predicted a crash; got a container reporting **healthy** for 3.0s while unable to serve |
| 4 | 137 read as "OOM"; the kernel applies no default signal action to **PID 1** |
| 5 | Predicted exit 7; got **56**, and the difference names the root cause |
| 6 | A p95 stuck at exactly `10` — the histogram was clamping, not the query failing |
| 7 | I asserted `external_labels` appear on local series. One query proved otherwise |
| 8 | 396 responses claiming `v1` while five v2 tasks ran — twice, for two different reasons |
| 9 | Five bugs in one deploy path, four of them found the slow way |

---

## Entry template

### N. <one-line title>

- **Stuck on:**
- **Prompt:**
  ```
  <exact prompt>
  ```
- **Answer I got:**
- **Did it work:**
- **What actually fixed it:**

---

### 1. Repo scaffolding and structure

- **Stuck on:** The brief is 300 marks across three scenarios and I did not know what
  order to build things in, or what could be written before I touched the VPS.
- **Prompt:**
  ```
  Here is my DevOps practical exam brief [pasted the whole brief]. I have an Ubuntu
  VPS with root, Docker on my Mac, a GitHub account and an AWS free tier account.
  Scaffold the whole submission repo first: everything that can be written locally
  without a server. Commit in logical chunks, not one big commit.
  ```
- **Answer I got:** A repo layout matching the required structure, plus the Scenario A
  app, healthcheck.sh, systemd units, nginx config, the Notes API, Dockerfiles,
  compose, Prometheus/Grafana config and the two GitHub Actions workflows.
- **Did it work:** As a starting point yes. It could not fill in anything that needs a
  real run — the exam token, my server IP, the real p95 numbers for the Grafana
  thresholds, the failover request counts, or the Scenario C tasks (my paste of
  Scenario C was truncated).
- **What actually fixed it:** Almost every number in the scaffold was a plausible
  guess that measurement later replaced, and two pieces of *structure* were
  wrong in ways that only running them exposed:
  - Grafana alert thresholds were written as round numbers (`p95 > 1s`). The
    measured p95 under load was **43.7s**, so the rule would have fired
    permanently and been ignored — see entry 6.
  - `stack.yml` set `APP_VERSION` in the service environment. That reads as
    good practice and is the exact bug in entry 8.
  - The `<<FILL>>` convention itself was the useful part: it made "I have not
    measured this yet" impossible to confuse with "I measured this", and the
    final pass was mechanical — grep for `FILL`, and the document is honest.
- **The real lesson:** an AI can lay out a repo and write config that is
  syntactically perfect and structurally sensible, and every *quantity* in it
  will still be invented. Treat generated numbers as placeholders even when they
  look reasonable, because a plausible number is harder to spot than an obviously
  wrong one.

### 2. AI told me curl was eating my config file. It was not.

- **Stuck on:** `healthcheck.sh` read a 4-line config and reported
  `all 1 checks passed`. It checked the first service and silently ignored the
  rest — no error, exit code 0.
- **Prompt:**
  ```
  My bash script reads a config file with `while IFS= read -r line; do ... done
  < "$CONFIG"` and runs curl inside the loop. It only processes the first line
  and then exits the loop as if the file ended. Why?
  ```
- **Answer I got:** That curl inherits the loop's stdin — which is the config
  file — and consumes the remaining lines, so `read` finds EOF on the next
  iteration. Fix: `curl ... < /dev/null`.
- **Did it work:** The symptom went away, so I believed it. **But it was the
  wrong explanation.** I had changed two things in the same edit — added
  `< /dev/null` AND replaced `date +%s%N` with curl's `%{time_total}` — and
  credited the wrong one.
- **How I caught it:** I made a copy of the script with only `< /dev/null`
  removed and ran both against the same config. **Both processed all 3 lines
  identically.** So I tested the claim directly:

  ```
  printf 'a\nb\nc\n' | while read -r l; do echo "read: $l"; curl -s ... ; done
    read: a   read: b   read: c        <- curl reads all three
  printf 'a\nb\nc\n' | while read -r l; do echo "read: $l"; cat >/dev/null; done
    read: a                            <- cat really does eat the rest
  ```

- **What actually fixed it:** `date +%s%N`. BSD date has no `%N`, so on macOS
  the expression became `(( 1788281524N - start ) / 1000000 )`, bash reported
  *value too great for base*, and **a failing arithmetic expansion aborts the
  entire enclosing compound command** — so the whole `while` loop was
  abandoned after one iteration, not just that iteration. I confirmed that
  separately too.
- **What I kept anyway:** `< /dev/null`, but described honestly as defensive
  habit rather than a fix. `ssh`, `mysql`, `ffmpeg` and `cat` genuinely do
  drain stdin in this loop shape — `ssh -n` exists for exactly this reason.
- **The real lesson:** the stdin story is a well-known, very plausible bash
  gotcha, which is exactly why both the AI and I accepted it without testing.
  Change one thing at a time, or you cannot tell which change was the fix.

### 3. "depends_on will crash the app" — it did not, and the truth was worse

- **Stuck on:** B2 task 26 asks what happens when the app starts before Postgres
  is ready. I wanted to know what to expect before running it.
- **Prompt:**
  ```
  docker compose with depends_on (no condition: service_healthy) starting a Node
  app that connects to Postgres. What happens on a fresh volume where Postgres
  has to run initdb?
  ```
- **Answer I got:** The app starts before Postgres is accepting connections, the
  driver throws ECONNREFUSED on startup, and the container exits and restarts
  until Postgres is up.
- **Did it work:** **No — the app never crashed at all.** I wrote that
  prediction into ANSWERS.md, ran it, and got a container that came up and
  stayed up.
- **What actually fixed it:** Three things the generic answer could not know
  about *my* app, all of which I had to find by reading my own code:
  1. `node-postgres`'s `Pool` is lazy — it opens no socket until the first
     query, so nothing connects at startup to fail.
  2. `app.listen()` does not touch the database, so the process is happily
     serving before Postgres exists.
  3. My `/healthz` is liveness-only, so Docker marked the container **healthy**
     while it could not have served a single real request.
  I measured the gap by polling `/healthz` and `/readyz` every 0.5s from
  `up -d`: **3.0 seconds of reporting healthy while unable to work.**
- **The real lesson:** the answer describes the *typical* stack, and the
  interesting behaviour lives in the differences from typical. "It lies about
  being healthy for three seconds" is a far more dangerous finding than "it
  crashes", and I would have missed it if I had trusted the prediction. Also:
  Postgres logs `ready to accept connections` **twice** on a fresh volume — the
  first is initdb's temporary server on a unix socket — so grepping the log for
  it is a trap; `pg_isready -h 127.0.0.1` is the check that means what you want.

### 4. Exit 137 where both of us expected 143

- **Stuck on:** `docker stop` on my container gave exit **137**, which everything
  I could find says means OOM-kill. Nothing was out of memory.
- **Prompt:**
  ```
  docker stop on a Node container gives exit code 137 instead of 143. The
  container is not out of memory. Why?
  ```
- **Answer I got:** 137 = 128+9 = SIGKILL, so Docker's 10-second grace period
  expired and it escalated — the app must be ignoring SIGTERM, so add a SIGTERM
  handler.
- **Did it work:** Right code arithmetic, wrong cause. My app **did** have a
  SIGTERM handler, and `ps` inside the container showed PID 1 was
  `node src/server.js` directly, not wrapped in a shell.
- **What actually fixed it:** The kernel does not apply **default signal actions
  to PID 1**. A normal process with no SIGTERM handler dies on SIGTERM; PID 1
  with no handler ignores it completely and has to be SIGKILLed. I proved it
  with four variants of the same image rather than arguing:

  | PID 1 | `docker stop` gives |
  | --- | --- |
  | `sleep 30` (no handler) | **137** — SIGKILL after the grace period |
  | same, with `--init` (tini) | **143** — tini forwards and reaps properly |
  | `sh -c "sleep 30"` | **137** — busybox `sh` exec-replaces itself, so `sleep` *is* PID 1 |
  | Node with a SIGTERM handler | **143** |

- **The real lesson:** 137 does **not** mean "out of memory". It means SIGKILL,
  and OOM is only one of the reasons something gets SIGKILLed. The only field
  that actually distinguishes them is `.State.OOMKilled` in `docker inspect`,
  and I now check that rather than reading the exit code as a diagnosis.

### 5. Predicted curl exit 7, got exit 56 — and the difference is the whole diagnosis

- **Stuck on:** B2 task 28d publishes a port but binds the app to `127.0.0.1`
  inside the container. I predicted what the client would see.
- **Prompt:**
  ```
  Docker container publishes -p 3120:3000 but the app inside binds to 127.0.0.1
  instead of 0.0.0.0. What does curl from the host see?
  ```
- **Answer I got:** Connection refused — curl exit 7.
- **Did it work:** **No. Exit 56, "Recv failure: Connection reset by peer".**
- **What actually fixed it:** `docker-proxy` is listening on the host port. It
  **accepts** the TCP connection — so there is nothing to refuse — and only then
  fails to forward it into the container, which is a reset *after* the
  handshake. That distinction turned out to be the most useful thing in the
  whole networking drill, because the three failures look identical in a browser
  and are completely different to debug:

  | What curl does | Exit | What it means |
  | --- | --- | --- |
  | instant RST | **7** | nothing is listening |
  | full timeout | **28** | packets are being dropped (firewall) |
  | connects, then empty reply | **56** | something accepted and could not forward |

- **The real lesson:** I nearly wrote "connection refused" into the answer
  without running it, because it is the phrase everyone uses for "the port does
  not work". The exit code is a real diagnostic signal and it distinguishes
  three completely different root causes — worth more than the sentence I would
  have written.

### 6. A histogram that could not report anything above 10 seconds

- **Stuck on:** Grafana Panel A showed p95 latency as exactly `10` and would not
  move, no matter how much load I put on. It looked like a broken query.
- **Prompt:**
  ```
  Prometheus histogram_quantile(0.95, ...) returns exactly 10 constantly in
  Grafana. The panel query looks right. What is wrong?
  ```
- **Answer I got:** Suggestions about `rate()` windows being too short, the
  scrape interval, and `by (le)` grouping — all reasonable, none of them it.
- **Did it work:** No. The query was fine.
- **What actually fixed it:** Counting the buckets by hand instead of reading
  the panel. For the `acme` tenant, `le="10"` held **293** samples while
  `le="+Inf"` held **408**. So 115 requests were slower than my largest finite
  bucket, and `histogram_quantile` cannot report a value above the highest
  finite boundary — it **clamps**, and reports the boundary. The panel was not
  broken; it was telling the truth about a histogram whose range was too small.
  Extending the buckets to 15/30/60s gave the real p95: **43.71 seconds.**
- **The real lesson:** this is one of the most dangerous shapes of bug, because
  the graph looks plausible and stable. It also invalidated an alert threshold I
  had already written from a guessed number. A quantile sitting exactly on a
  round number that happens to be your top bucket is the tell, and the check is
  always `le="<top>"` versus `le="+Inf"`.

### 7. I stated something confidently and it was wrong: `external_labels`

- **Stuck on:** B3 task 30 asks what `external_labels` in `prometheus.yml` does.
  I wrote the answer before checking.
- **Prompt:**
  ```
  What do external_labels in prometheus.yml do, and where do they show up?
  ```
- **Answer I got:** That they identify this Prometheus instance and are attached
  to its series.
- **Did it work:** I wrote in ANSWERS.md that they appear on local series. Then
  I queried for `env="exam"` against my own running Prometheus and got
  **`(no data)`**.
- **What actually fixed it:** `external_labels` apply **only** when data leaves
  the instance — `remote_write`, federation, and alerts sent to Alertmanager.
  They are never attached to locally stored series, which is exactly why they
  are safe: they cannot collide with a label a target already exposes.
- **The real lesson:** the wording "identify this instance" is true and told me
  nothing about *where*, and I filled that gap in with an assumption. The
  correction cost one query. I have kept the wrong version and the query that
  killed it in ANSWERS.md, because "I checked and I was wrong" is worth more to
  a marker than a sentence that happens to be right.

### 8. The version endpoint that lied during exactly the operation it exists for

- **Stuck on:** B4 task 37's rolling update produced 396 responses, all HTTP 200,
  every one reporting `v1` — while `docker service ps` showed five **v2** tasks
  running.
- **Prompt:**
  ```
  docker service update --image myimage:v2 completes, docker service ps shows
  all tasks on v2, but every HTTP response still reports version v1. The image
  has ENV APP_VERSION=v2 baked in. Why?
  ```
- **Answer I got:** Suggestions about caching, the wrong image being pushed, and
  needing `--force`.
- **Did it work:** No, and I could have chased the "wrong image pushed" idea for
  a long time. `docker manifest inspect` showed v2 was in the registry
  correctly.
- **What actually fixed it:** Reading the service spec instead of theorising —
  `docker service inspect --format '{{json .Spec…Env}}'` returned
  `["APP_VERSION=v1", …]`. My `stack.yml` set `APP_VERSION` in the service
  environment, a **container env var overrides the image's own `ENV`**, and
  `--image` updates change the image and nothing else. Everything else that ever
  drifted into the service spec survives an image roll untouched.
- **And the same bug had a second half.** After fixing that, CI images tagged
  `v1.0.66` still reported `v1` — because the Dockerfile had `ENV APP_VERSION=v1`
  as a **constant**. I had obeyed "bake the version into the artefact" while
  baking in something fixed. Now `ARG APP_VERSION` with CI passing the version it
  derived.
- **The real lesson:** a version indicator supplied by deployment config rather
  than by the artefact will lie during exactly the operation it exists to
  describe. The dangerous property of the second half is that it raises **no red
  light at all** — the deploy is green, `/healthz` returns 200, and the endpoint
  whose job is to answer "which code is running?" answers the same thing
  forever.

### 9. Debugging a deploy script inside CI, which is the slowest possible place

- **Stuck on:** The GitHub Actions deploy job failed twice while production was
  healthy and correctly updated both times. Each attempt cost a build, a queue,
  a manual approval and five to fifteen minutes.
- **Prompt:**
  ```
  My GitHub Actions deploy step runs docker service update over SSH. It updated
  all replicas successfully and then failed with
  "client_loop: send disconnect: Broken pipe" and exit 255.
  ```
- **Answer I got:** Add `ServerAliveInterval` — which was correct, and fixed the
  first of five separate bugs.
- **Did it work:** It fixed that one. Then the next run hung for eight minutes on
  `overall progress: 0 out of 3 tasks` while `UpdateStatus` said `completed`
  after 93 seconds. Then the run after that hung on `health poll 1/30`. Each
  defect was invisible until the one in front of it was cleared:

  | # | Bug | Why it stayed hidden |
  | --- | --- | --- |
  | 1 | no SSH keepalive | — |
  | 2 | progress bar never converges (a leftover task with an empty `NodeID`) | needed 1 fixed to reach |
  | 3 | `APP_VERSION` baked in as a constant | needed 1 and 2 fixed to reach |
  | 4 | `curl` with no timeout against `localhost` (resolves `::1` first) | needed 1 and 2 fixed to reach |
  | 5 | `{{.UpdateStatus.State}}` dies when the field is absent | CI never hits it; a manual re-run does |

- **What actually fixed it:** Running the same script by hand over SSH, which
  found bug 5 in about ten seconds — and would have found 2, 3 and 4 just as
  fast. Bug 4 is the sharpest example of a general point: it never printed
  `poll 2/30`, so `curl` had **blocked on the first call** rather than being
  slow, and that distinction is what identified it. Every one of my Scenario B4
  scripts already used `127.0.0.1` with `--max-time`; this script had drifted
  off the habit.
- **The real lesson:** a deploy script is the slowest possible thing to debug
  from inside CI and is almost always runnable directly. Beyond that: **a
  pipeline's verdict is a statement about the pipeline.** Twice it reported
  failure over a healthy, correctly-updated production; in B4 task 38 Swarm
  reported `update completed` over a service returning 500 to every request.
  Both directions point the same way — ask production, not the tool.
