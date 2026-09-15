# TIMELINE

Work diary. Newest entries at the bottom. Times are local (Asia/Dhaka).

Format: `YYYY-MM-DD HH:MM — what I did — what went wrong — how long`

## Day 1

| When | What | Outcome |
| --- | --- | --- |
| 09-01 19:20 | Generated `$EXAM_TOKEN`, surveyed the VPS before touching anything | Found `alice`/`bob`/`carol`/`dan`, `devs`/`ops`/`auditor` and `/srv/app` **already existed** — two other students (`ashik`, `badhon`) share this box. Namespaced everything as `abdur` |
| 09-01 20:13 | `setup-users.sh` — users, groups, ACLs, `chattr +i`, sudoers | All created. Guard added so the script refuses to run if an unprefixed shared name reappears |
| 09-01 20:17 | `abdur-myapp.service` on port 3100 | `active (running)` |
| 09-01 20:33 | `verify-a1.sh` — the 12 proof checks | **PASS=12 FAIL=0**. A1 done |
| 09-01 21:00 | A2 — port forensics on 8180/8181 | cgroup identified it as hand-started; `kill -9` on the systemd unit came back as a new PID |
| 09-01 21:13 | A2 task 8 from the laptop | refused = 264 ms, timed out = 6005 ms. Another student's `DROP` rule on 8080 supplied the timeout case |
| 09-02 20:08 | A3 break tests | Found a **real bug**: an unopenable lock file killed the run before the config check. Fixed to warn and continue |
| 09-02 20:14 | A3 flock guard, first real test | Second copy declined at 20:14:43 while the first held the lock. Was untested until now (no `flock` on macOS) |
| 09-02 20:15 | A3 cron | Two runs, 20:10:02 and 20:15:01. Appended to root's crontab — another student's job was already in it |
| 09-02 20:27 | A4 task 13 crash loop | 5 restarts then `Start request repeated too quickly`, `failed`, port dead |
| 09-02 20:30 | A4 task 13b `Restart=always` | Never gives up. `Result: success` after six crashes — the dangerous part |
| 09-02 20:32 | A4 task 14 journalctl | `-b -1` failed, but not for the usual reason: journal *is* persistent, the VPS has simply never rebooted |
| 09-02 20:36 | A4 task 15 watchdog | Hung app stayed `active (running)` with the same PID while curl timed out. Watchdog restarted it in 30s |
| 09-02 20:43 | A5 nginx config | `nginx -t` **rejected it** — `limit_req_status` duplicated another student's http-context directive. Moved it into my `server{}` block |
| 09-02 20:48 | A5 task 17 | RR 50/50, `least_conn` 52/48, `ip_hash` 100/0. Learned round-robin state is per worker |
| 09-02 20:58 | A5 task 18 failover | Client saw 0 failures; nginx logged 16. `max_fails` is per worker: 4 workers × 4 lines |
| 09-02 21:08 | A5 tasks 19/20 | 504 at 5.009s, 200 at 45.016s; 29×404 + 21×429. A single `/slow` timeout ejected a healthy backend |
| 09-02 21:11 | A5 task 16 from the laptop | `x-real-ip: 103.126.60.85` while the app's own `remoteAddress` stayed `127.0.0.1` |

| 09-03 22:10 | B1 tasks 21–25 | Multi-stage Dockerfile built and measured. `docker history` showed the npm-removal `RUN` does not shrink the image — deleting in a later layer cannot remove earlier bytes |
| 09-03 23:40 | B2 task 26 | `depends_on` did NOT crash the app as I predicted. Lazy pg Pool + a liveness-only `/healthz` meant it reported **healthy for 3.0s while the DB was still doing initdb** — a stronger finding than the crash |
| 09-04 00:10 | B2 task 27 | First run was vacuous: every POST returned `unknown tenant` because the seeder had never run, and all four counts were 0. Added seeding to setup only |
| 09-04 00:40 | B2 task 28 | Predicted `docker stop` → 143; got **137**. The kernel applies no default signal action to PID 1. Proved it with four variants; tini gave 143 |
| 09-04 01:05 | B2 task 28 OOM | `Buffer.alloc(10MB)` took **87s** to OOM, `.fill(1)` took **<1s** — cgroups charge resident pages, and my first test's `sleep 15` was shorter than the failure |
| 09-04 01:30 | B2 task 28 network | Predicted curl exit 7; got **56**. docker-proxy accepts the connection and then cannot forward it |
| 09-04 02:20 | B3 task 29 | Three greps printed nothing and looked like missing metrics. prom-client's label order is not stable: `_bucket` emits `{le,app,route}` while `_sum` emits `{app,route}`. Wrote `metricfmt.py` to stop guessing |
| 09-04 02:40 | B3 task 30 | Eight of nine inline `python3 -c` formatters died on `\"` inside an f-string. Moved them to `promfmt.py` as a file |
| 09-04 03:00 | B3 task 31 | 1218 `notes_list` calls against 1158 recorded requests — a 60-request gap that exposed three instrumentation bugs: `finish` vs `close`, an in-flight gauge leaking to 63, and the AsyncLocalStorage store captured too late |
| 09-04 03:02 | B3 task 32 | Dashboard rendered. Panel A reported p95 = exactly `10` — the top bucket. `le=10` held 293 of 408 samples: the histogram was clamping. Extended buckets; true p95 **43.71s** |
| 09-04 03:11 | B3 task 34 | The write-cost benchmark said the index made INSERTs *faster*. Unfair comparison. Settled it by counting WAL instead of timing: **+10,104 records, +46% bytes**, replicated to the byte |
| 09-04 13:30 | B4 task 35 | Swarm init, images to GHCR. The worker join token leaked into the evidence file — rotated both tokens first, redacted second |
| 09-04 15:30 | B4 task 37 | 396 responses all said `v1` while five v2 tasks were running. `stack.yml` set `APP_VERSION` in the service env, and container env overrides image `ENV`. `--image` updates change only the image |
| 09-04 15:40 | B4 task 38 | With a healthcheck: `rollback_completed` in 33s, clients saw 124/124 200s. Without one: Swarm said **"update completed"** for a service returning 500 to 184 of 327 requests |
| 09-04 15:55 | B4 task 39 | Same impossible 16G both ways on a 7.76 GiB node: as a **limit** it was accepted and `memory.max` read 16 GiB; as a **reservation** the task sat `Pending`, `NodeID` empty, forever |
| 09-04 16:15 | B4 task 40 | 2116 requests, zero failures. Two of three pinned sockets were on tasks that got deleted and both migrated mid-flight; the third, on a survivor, never reconnected — the control that makes the other two mean something |
| 09-04 14:30 | B5 task 41 | PR #1 carried a deliberate cross-tenant leak. 9 of 10 tests passed; one assertion stood between it and production. The *other* by-id test passed too — a nonexistent id returns zero rows either way |
| 09-04 14:40 | B5 task 42 | First cache measurement was contaminated: a "fresh branch" build was warm from `main`'s cache. Deleted all 60 entries and used two empty commits. Build **83s → 12s**, but the test job got *slower* — the Postgres pull varies more than npm caching saves |
| 09-04 17:00 | B5 task 44 | The deploy succeeded and the pipeline called it a failure — twice, for two different reasons. Five bugs, each hidden behind the last: SSH keepalive, a progress bar that never converges, `APP_VERSION` baked in as a constant, `curl` with no timeout against `localhost`, and a template that dies when `UpdateStatus` is absent |
| 09-04 18:10 | B5 task 45 | Changed my own plan: "wrong service name" proves nothing, so failure 3 deployed a **well-formed tag that was never built**. Rollback in 17s; the three replicas read "Running 24–25 minutes" *after* the bad deploy, so they were never touched. Also produced the `Rejected` task B4 task 38 could not |
| 09-04 18:29 | B5 task 46 | The concurrency group caught a real race unprompted: two pushes 110s apart, the older `waiting` at the approval gate and holding the group, the **newer** one `pending` behind it |
| 09-05 00:30 | Audit | Cross-checked every evidence reference in both directions. Found `INCOMPLETE.md` still claiming B1–B5 were unrun, task 12 with no answer section, and eight evidence files cited by nothing |
| 09-12 | C0 constraints | Opened every service console before creating anything. Billing figures `Access denied`, Budgets already "1 over budget", and `exam-deployer` already taken by another student — everything of mine prefixed `abdur-` |
| 09-13 00:49 | C1 task 47 | Push-and-deny script run 1 "proved" six denials — all were malformed-signature errors, because a pasted command block had answered the key prompt. Hardened the script. Run 2: I had claimed `docker push` never needs `ecr:BatchGetImage`; the push was refused at the manifest step. Run 3 clean |
| 09-14 02:05 | C2 task 49 | `v1.0.69` pushed to ECR, amd64 manifest only — digest differs from the GHCR index |
| 09-15 00:16 | C2 task 50 | Standalone Fargate task against private RDS: migrations applied on the first attempt. Stopped at 00:39 — exit code 0, graceful SIGTERM |
| 09-15 01:29 | C2 | CloudShell refused ("account verification in progress"). Installed AWS CLI on the laptop, `aws login` — no access key |
| 09-15 01:37 | C2 task 51 | Run 1 stopped: my JMESPath existence check miscounted and re-added a rule that existed. Run 2: ALB + 2 tasks, 12 requests split 6/6 |
| 09-15 01:51 | C2 task 52 | The brief's `hey -c 50` did not scale: CPU plateaued at 40 %, limited by the 185 ms round trip from Dhaka. Run 2 stopped on re-registering a tagged scalable target. Run 3 (`-c 120`): 2 → 3 at 02:06:29 — **after** the load had ended — and back to 2 at 02:24 |
| 09-15 02:37 | C2 task 54 | Broke the health-check path. Users saw 200 throughout (ALB fail-open) while ECS killed four tasks in four minutes. Fixed in 44 s |
| 09-15 18:34 | C2 | Resumed after 16 h: login expired, the two graph screenshots had been retaken with the wrong time range. Rendered both graphs with `get-metric-widget-image` for the fixed window |
| 09-15 18:56 | C2 task 53 | Deploy run #34 would not start: a B5 approval from 09-04 had held `deploy-main` for eleven days and silently cancelled every later deploy. Rejected it |
| 09-15 19:07 | C2 task 53 | Attempt 1: `AssumeRoleWithWebIdentity` denied — this repo uses GitHub's immutable OIDC subject. Attempt 2: `GetDownloadUrlForLayer` denied during the image copy. Attempt 3 green: revision 2, `verify-full` TLS to RDS |
| 09-15 19:24 | C3 task 57 | CloudFront refused by the same account-verification state. Fell back to a bucket policy on `public/*` |
| 09-15 19:36 | C3 tasks 55–58 | All proofs first time: upload 200; `Request has expired` at 61 s; public/private/presigned; acme → globex 403 before signing |
| 09-15 21:26 | C4 install | Run 1: `nginx -t` failed — a placeholder substituted inside a comment. Restore worked, nothing reloaded. Run 2 at 21:29 clean |
| 09-15 21:34 | C4 tasks 59–62 | 59–62.2 proved. 62.3/62.4 "fixed" halves checked inside the nginx reload window and showed the old behaviour. Installer now waits; re-run at 21:48 correct three times each |
| 09-15 22:04 | C5 task 63 | Deleted every `abdur` resource in dependency order in six minutes; brief's listings empty apart from another student's bucket |


**Honesty note on this file.** The Scenario C rows (09-12 onward) were added on
09-15 from the timestamps inside `scenario-c/evidence/`, the git log and the
GitHub Actions run history, not typed as each thing happened.

The Scenario A rows were written as the work
happened. The Scenario B rows (09-03 onward) were reconstructed on 09-05 from
git commit timestamps and the timestamps inside `evidence/`, because during B
I was writing findings straight into ANSWERS.md and let this file lag. The
times and the findings are accurate — they come from the transcripts — but I
did not type them at the moment each thing happened, and the instruction below
says not to do that, so it is recorded rather than glossed over.

<!--
Fill this in AS YOU GO, not at the end. The marker is looking for a plausible
sequence of work, including the dead ends. Entries that show a failure and the
recovery are worth more than a clean list of successes.
-->