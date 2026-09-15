# INCOMPLETE

Honest status, kept current. The marking rule this file exists for:

> A task failed but diagnosed correctly earns up to 60%.
> A task skipped silently earns 0.

**Last updated: 2026-09-15.**

## What is finished

| Scenario | Marks | Status |
| --- | --- | --- |
| A — the inherited server (tasks 1–20) | 82 | **complete**, executed on the VPS |
| B1 — Dockerfiles (21–25) | 18 | **complete**, executed |
| B2 — compose + drills (26–28) | 18 | **complete**, executed |
| B3 — metrics, Prometheus, Grafana (29–34) | 32 | **complete**, executed |
| B4 — Swarm (35–40) | 26 | **complete**, executed |
| B5 — CI/CD (41–46) | 30 | **complete**, executed |
| C1 — IAM (47–48) | 8 | **complete**, executed |
| C2 — ECS, ALB, autoscaling, CI/CD, debugging (49–54) | 36 | **complete**, executed |
| C3 — S3 and presigned URLs (55–58) | 20 | **complete**, executed |
| C4 — multi-tenancy with subdomains (59–62) | 26 | **complete**, executed on the VPS; all four 62 points demonstrated |
| C5 — clean up (63) | 4 | **complete**: every `abdur` resource deleted and verified |

Every number in the three `ANSWERS.md` files is measured, and every task has a
transcript or screenshot in the corresponding `evidence/` directory.
Where a prediction of mine turned out wrong, the wrong prediction and the
measurement that corrected it are both kept — there are around twenty of them.

## Scenario C — complete, with these declared deviations

Nothing in C was skipped. These are the places where what was built differs
from the brief's literal wording, each explained in `scenario-c/ANSWERS.md`:

1. **`exam-deployer` is `abdur-exam-deployer`** (task 47) — the plain name
   already belonged to another student in the shared AWS account.
2. **CloudShell could not be used** — the account was "verification in
   progress", an owner-only state. C2–C5 ran from the AWS CLI on my laptop,
   authenticated with `aws login` (no access key for the console user).
3. **Task 55's "leave all public access blocked on" is not literally true at the
   end.** Task 57 needs `public/*` readable by a plain URL; the design that keeps
   every block on (CloudFront with Origin Access Control) was refused by the same
   account-verification state. The two *policy* blocks were turned off on that one
   bucket, the two ACL blocks stayed on, and the bucket policy allows `GetObject`
   on `public/*` only.
4. **C4 runs on port 8141, not 80** — port 80's default server on the shared VPS
   belongs to another student, and 62.1 needs my own default server. Domains are
   real public DNS (nip.io wildcard, sslip.io as the second domain); no
   `/etc/hosts`.
5. **Two C4 runs failed before they succeeded**, both kept as evidence: the
   installer's first `nginx -t` failed (a placeholder substituted inside a
   comment — the safety net restored the old config, nothing reloaded), and the
   first demo of 62.3/62.4 checked "fixed" inside the nginx reload window.
6. **How C was done:** from task 51 onward the scripts and code were written and
   run by Claude Code at my request; I ran every step that needed me (browser
   login, GitHub production approvals, every command on the shared VPS) and took
   every screenshot. Recorded in `AI_PROMPTS.md`, entries 10–15.

## Bonus — AI_PROMPTS.md

**Complete: 15 entries against a minimum of 8.** Thirteen of them are cases
where the answer I was given, or the prediction I wrote from it, was wrong and a
measurement corrected it — which is the part the marks are for, rather than the
prompts themselves.

## Screenshots still to capture

| File | Source |
| --- | --- |
| `scenario-b/evidence/b5-approval-approved.png` | Actions run 33903125661 — the production approval |

It is also captured as text (`scenario-b/evidence/b5-approval-pending.txt`,
`b5-deploy-green.txt`), so no claim rests on the image alone. The other four B5
images listed here on 2026-09-05 now exist.

Two image files in `scenario-c/evidence/` are not cited by `ANSWERS.md`:
`exam-token.png` (a full-screen capture of the stopped task-50 task, kept at my
request) and `CleanShot 2026-09-15 at 20.11.19.png` (a second capture of the C4
recon output, same minute as `c4-vps-recon.png`).

## Known limits I chose not to fix

These are deliberate, not oversights.

1. **An aborted HTTP request is not cancelled server-side.** B3 task 31: a
   `curl --max-time 3` against `?limit=5000` left the app running its remaining
   sequential queries for a further ~40 seconds, producing a response nobody
   would read. Instrumentation now *records* those requests (status 499), but
   the work itself is not stopped. The fix is to abort on `res.on('close')` —
   an `AbortController` threaded through `db.query()`, or a per-request
   cancelled flag checked inside the tag loop. Left undone because it changes
   request handling rather than measurement, and B3 is marked on measurement.

2. **`db_queries_per_request` undercounts aborted requests.** It observes at the
   moment of the abort, so the final load run recorded ~46,000 of the ~99,900
   queries actually executed for `/api/notes` — about 46%. The per-query metrics
   (`db_rows_returned`, `db_query_duration_seconds`) show the true figure, so
   nothing is unmeasurable; the per-request histogram simply must not be read as
   "database load". Fixing it properly requires (1).

3. **`--omit=dev` saves 0 bytes in this image**, because `devDependencies` is
   empty. The flag stays as policy, and B1's size table says so rather than
   quoting a plausible-looking number.

4. **Multi-arch builds roughly double CI time**, since the non-native
   architecture builds under QEMU. Kept because the VPS is amd64 and my laptop
   is arm64; an arm64-only image fails on the VPS with `exec format error`,
   which reads like a corrupt binary rather than an architecture mismatch.

5. **`depends_on: !reset []`** in `docker/drills/28b-dns.yml` needs Compose
   v2.24+. A plain-`docker run` fallback is in that file's comments.

6. **C4 trusts `X-Tenant` from anyone who reaches port 3140 directly.** nginx on
   8141 always overwrites it, but the swarm routing mesh publishes 3140 on all
   interfaces. With no authentication in this app that grants nothing a visitor
   to the tenant's subdomain does not already have; with authentication, 3140
   would have to be firewalled to localhost or nginx would add a secret the app
   checks.

7. **Custom-domain verification checks only that DNS points at the service**
   (task 61). A production service would require a per-claim TXT token.

8. **The `deploy-ecs` CI job has nothing left to deploy to** after task 63; a push
   to `main` without `[skip ci]` would fail at its first step. Left as the task 53
   deliverable.

## Things that were unverified and now are not

Kept for the record, because the verification changed the answers.

1. ~~The Grafana dashboard has never rendered.~~ **Loaded and confirmed under
   load.** Doing so found two real bugs: the latency histogram was clamping at
   its top bucket (panels reported exactly `10s`; the true p95 was 43.7s), and
   panel D was rendering `363 calls/sec` as `6.06 mins` from an inherited unit.
2. ~~`healthcheck.sh`'s `flock` guard is untested.~~ **Verified on the VPS**
   (2026-09-02 20:14:41–51). Testing it surfaced a real bug: an unopenable lock
   file was killing the run before it reached the config check.
3. ~~`chattr +i` depends on the filesystem.~~ **Confirmed ext4 on this VPS**, and
   carol's `rm` returns `Operation not permitted`.
4. ~~B4 needs the image pushed to GHCR first.~~ Done; `v1`, `v2`, `v3` pushed by
   hand for the rollout experiments, and `v1.0.<n>` / `sha-<full>` / `latest` by
   CI.
