# INCOMPLETE

Honest status, kept current. The marking rule this file exists for:

> A task failed but diagnosed correctly earns up to 60%.
> A task skipped silently earns 0.

**Last updated: 2026-09-05.**

## What is finished

| Scenario | Marks | Status |
| --- | --- | --- |
| A — the inherited server (tasks 1–20) | 82 | **complete**, executed on the VPS |
| B1 — Dockerfiles (21–25) | 18 | **complete**, executed |
| B2 — compose + drills (26–28) | 18 | **complete**, executed |
| B3 — metrics, Prometheus, Grafana (29–34) | 32 | **complete**, executed |
| B4 — Swarm (35–40) | 26 | **complete**, executed |
| B5 — CI/CD (41–46) | 30 | **complete**, executed |

Every number in `scenario-a/ANSWERS.md` and `scenario-b/ANSWERS.md` is measured,
and every task has a transcript in the corresponding `evidence/` directory.
Where a prediction of mine turned out wrong, the wrong prediction and the
measurement that corrected it are both kept — there are around twenty of them.

## Scenario C — not started (94 marks at risk)

- **Status:** not started. This is the single largest outstanding item.
- **Why:** the copy of the brief I was working from was **truncated
  mid-sentence** in the cost warning — "use free tier. `t3.micro` o…" — so the
  individual task numbers and requirements were never available to me.
- **How far I got:** `scenario-c/ANSWERS.md` records what the section header
  establishes, plus the pieces already built that feed into it — an OIDC-ready
  `deploy.yml` with `id-token: write` and no static AWS keys anywhere, the
  trust-policy `sub` condition scoping the role to one repo and branch, the
  security-group reasoning about port 22, and the multi-tenant app itself.
- **Next:** obtain the full Scenario C text, transcribe the tasks, execute.

## Bonus — AI_PROMPTS.md

**1 of the minimum 8 entries written.** The remaining seven are being filled
from real problems encountered during execution. Entries that only paste a
prompt score 2 marks, so each needs the "what was wrong with the answer" and
"what I actually changed" parts.

## Screenshots still to capture

The prose and the machine-readable transcripts for these exist; the image files
do not yet:

| File | Source |
| --- | --- |
| `scenario-b/evidence/b5-pr-failed.png` | Actions run 33884146208 |
| `scenario-b/evidence/b5-pr-passed.png` | Actions run 33884321458 |
| `scenario-b/evidence/b5-ghcr-tags.png` | the GHCR package page |
| `scenario-b/evidence/b5-approval-approved.png` | Actions run 33903125661 |
| `scenario-b/evidence/b5-vps-new-version.png` | `http://169.58.246.108:3140/healthz` |

Every one of these is also captured as text in the same directory
(`b5-pr-failed.txt`, `b5-cache.txt`, `b5-deploy-green.txt`,
`b5-approval-pending.txt`, `b5-prod-survived.txt`), so no claim in ANSWERS.md
rests on an image alone.

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
