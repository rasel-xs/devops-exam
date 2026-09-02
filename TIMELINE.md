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

<!--
Fill this in AS YOU GO, not at the end. The marker is looking for a plausible
sequence of work, including the dead ends. Entries that show a failure and the
recovery are worth more than a clean list of successes.
-->
