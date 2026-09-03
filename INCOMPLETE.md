# INCOMPLETE

Honest status. Everything in this repo has been **written and committed**;
almost none of it has been **executed on real infrastructure** yet. The
distinction matters for marking, so it is stated per item rather than hidden.

> The marking rule: a task failed but diagnosed correctly earns up to 60%.
> A task skipped silently earns 0.

## Scenario C — not started (94 marks at risk)

- **Status:** not started.
- **Why:** the copy of the brief I was working from was **truncated
  mid-sentence** in the cost warning — "use free tier. `t3.micro` o…" — so the
  individual task numbers and requirements were never available to me.
- **How far I got:** `scenario-c/ANSWERS.md` records what the section header
  establishes, and the pieces already built that feed it: OIDC-ready
  `deploy.yml` with `id-token: write` and no static AWS keys anywhere, the
  trust-policy `sub` condition that scopes the role to one repo and branch, the
  security-group rule about port 22, and the multi-tenant app itself.
- **Next:** obtain the full Scenario C text, transcribe the tasks, execute.

## Everything else — written, not yet run

| Area | Written | Run on real infra | What is missing |
| --- | --- | --- | --- |
| A1 users/ACL/sudo | yes | **DONE** | `verify-a1.sh` PASS=12 FAIL=0, `evidence/a1-proof-table.txt` |
| A2 port forensics | yes | **DONE** | tasks 5-8, `evidence/a2-session.txt` + `a2-task8-from-laptop.txt` |
| A3 healthcheck.sh | yes | **DONE** | tasks 9-11 incl. the flock guard and two cron runs, `evidence/a3-session.txt` |
| A4 systemd | yes | **DONE** | tasks 12-15, restart limit hit at 5, watchdog recovery 30s |
| A5 nginx | yes | **DONE** | tasks 16-20, all numbers measured |
| B1 Dockerfiles | yes | no | Docker Desktop was not running on this machine — image sizes, layer-cache times and `docker history` are all `<<FILL>>` |
| B2 compose + drills | yes | no | the four drills are scripted but not executed |
| B3 metrics/Prom/Grafana | yes | no | dashboard JSON is hand-built and **not yet loaded into a running Grafana**; panel screenshots and every threshold number are outstanding |
| B4 Swarm | yes | no | needs the image pushed to GHCR first |
| B5 CI/CD | yes | no | needs the repo pushed; the PR-fail/PR-pass run URLs are `<<FILL>>` |

### Specific things I know are unverified

1. **The Grafana dashboard has never rendered.** The PromQL is written against
   the metric names this app actually exposes, and the datasource uid is pinned,
   but panel geometry and the table transformations in Panel D are the parts
   most likely to need adjusting in the UI. A dashboard with no data is
   explicitly called out in the brief as a viva trigger — so these panels must
   be confirmed against real data before submission, not assumed.
2. ~~`healthcheck.sh`'s `flock` guard is untested.~~ **Now verified on the VPS**
   (2026-09-02 20:14:41-51): a slow run held the lock for 9s while a second
   copy started at 20:14:43, declined, and exited 0. Testing it also surfaced a
   real bug — an unopenable lock file was killing the run before it reached the
   config check — now fixed.
3. ~~`chattr +i` depends on the filesystem.~~ **Confirmed ext4 on this VPS**,
   and carol's `rm` returns `Operation not permitted` as required.
4. **`depends_on: !reset []`** in `docker/drills/28b-dns.yml` needs Compose
   v2.24+. A plain-`docker run` fallback is in the file's comments.

**Scenario A is complete (82/82 marks attempted).** Every task from A1 to A5 has
been executed on the VPS and has a transcript in `scenario-a/evidence/`.
5. **Multi-arch builds double CI time.** If Actions minutes become a constraint,
   drop `linux/arm64` and say so in ANSWERS rather than letting builds time out.

### Known limits I chose not to fix

6. **An aborted HTTP request is not cancelled server-side.** B3 task 31: a
   `curl --max-time 3` against `?limit=5000` left the app running its remaining
   sequential queries for a further ~40 seconds, producing a response nobody
   would read. Instrumentation now *records* those requests (status 499), but
   the work itself is not stopped. The fix is to abort on `res.on('close')` —
   an `AbortController` threaded through `db.query()`, or checking a
   per-request cancelled flag inside the tag loop. Left undone because it
   changes request handling rather than measurement, and measurement is what
   B3 is marked on.

7. **`db_queries_per_request` undercounts aborted requests.** It observes at
   the moment of the abort, so the final run recorded ~46,000 of the ~99,900
   queries actually executed for `/api/notes` — about 46%. The per-query
   metrics (`db_rows_returned`, `db_query_duration_seconds`) show the true
   figure, so nothing is unmeasurable; the per-request histogram simply must
   not be read as "database load". Fixing it properly requires (6).

### Bonus marks — AI_PROMPTS.md

Only **1 of the minimum 8** entries is written. The remaining seven must be
filled in from real problems encountered during execution; the file lists
candidate topics as comments. Entries that just paste a prompt score 2 marks,
so each needs the "what was wrong with the answer" and "what I actually
changed" parts.
