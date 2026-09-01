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
| A1 users/ACL/sudo | yes | no | run `setup-users.sh` + `verify-a1.sh`, capture the 12-row proof table |
| A2 port forensics | n/a (live task) | no | must be done interactively on the VPS |
| A3 healthcheck.sh | yes, and unit-exercised locally | partially | tested on macOS: exit 2, exit 1, no-hang and the mixed pass/fail summary all verified. Not yet run under cron on the VPS, and the `flock` concurrency guard is **untested** because macOS has no `flock` |
| A4 systemd | yes | no | crash loop, journalctl queries, watchdog timing all need the VPS |
| A5 nginx | yes | no | all measured numbers (distribution, failover counts, 504 timings, 429 counts) are `<<FILL>>` |
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
2. **`healthcheck.sh`'s `flock` guard is untested.** It falls back to a loud
   warning when `flock` is absent (which is how I found the bug where a missing
   binary read as "lock held"), but the actual two-copies-at-once behaviour has
   only been reasoned about, not observed. Test on the VPS with the command in
   `configs/crontab-entry.txt`.
3. **`chattr +i` depends on the filesystem.** It works on ext4/xfs and not on
   overlayfs or tmpfs. If `/srv` on the VPS turns out to be something exotic,
   task 3 needs a different approach and the ANSWERS entry must say so.
4. **`depends_on: !reset []`** in `docker/drills/28b-dns.yml` needs Compose
   v2.24+. A plain-`docker run` fallback is in the file's comments.
5. **Multi-arch builds double CI time.** If Actions minutes become a constraint,
   drop `linux/arm64` and say so in ANSWERS rather than letting builds time out.

### Bonus marks — AI_PROMPTS.md

Only **1 of the minimum 8** entries is written. The remaining seven must be
filled in from real problems encountered during execution; the file lists
candidate topics as comments. Entries that just paste a prompt score 2 marks,
so each needs the "what was wrong with the answer" and "what I actually
changed" parts.
