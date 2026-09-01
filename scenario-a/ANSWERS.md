# Scenario A — Answers

**Exam token:** `root-vmi3536696-1788282556-1536d427`
**Server:** `169.58.246.108` — Ubuntu REPLACE_ME (`lsb_release -ds`)

> Placeholders written as `<<FILL: ...>>` are numbers that only exist once the
> command has actually been run on the server. Fill them from your own output —
> the marker cross-checks the prose against the screenshots.

---

## A1 — Team access

Everything is created by [`configs/setup-users.sh`](configs/setup-users.sh) and proved by
[`configs/verify-a1.sh`](configs/verify-a1.sh), whose full output is in
[`evidence/a1-proof-table.txt`](evidence/a1-proof-table.txt).

### The access model

| Path | Owner:Group | Mode | ACL | Why |
| --- | --- | --- | --- | --- |
| `/srv/abdur/app` | root:root | 0755 | — | a doorway; traversable, not writable |
| `/srv/abdur/app/src` | root:abdur_devs | 2770 | `g:abdur_auditor:r-x`, `u:abdur_myappuser:r-x` | abdur_devs (incl. abdur_carol) edit; abdur_dan reads; service reads |
| `/srv/abdur/app/config` | root:abdur_ops | 2770 | `g:abdur_devs:r-x`, `g:abdur_auditor:r-x`, `u:abdur_myappuser:r-x` | abdur_ops edit, abdur_devs and abdur_dan read |
| `/srv/abdur/app/secrets` | root:abdur_ops | 0750 | `g:abdur_auditor:r-x` **on the directory only** | abdur_ops read; abdur_dan lists |
| `/srv/abdur/app/secrets/db-password.txt` | root:abdur_ops | 0640 | **none** | abdur_ops read; nobody else |
| `/srv/abdur/app/logs` | abdur_myappuser:abdur_devs | 2770 | `g:abdur_auditor:r-x` | app writes, abdur_devs and abdur_dan read |
| `/srv/abdur/app/backups` | abdur_carol:abdur_ops | 3770 + `chattr +i` on files | `g:abdur_auditor:r-x` | abdur_carol owns it and still cannot delete |

`others` is `---` on every subdirectory. Nothing is world-readable; every
cross-team read is an explicit ACL entry, so `getfacl -R /srv/abdur/app` *is* the
documentation the previous sysadmin never wrote.

### Task 2 — Why abdur_dan can list the folder but not read the file

Permissions on a *directory* and permissions on the *files inside it* are
independent checks. Read (`r`) on a directory means "you may read the list of
names stored in it" and execute (`x`) means "you may resolve a name in it to its
inode", which is what `ls -l` needs in order to `stat()` each entry and print
its size, owner and mode. abdur_dan has `r-x` on `/srv/abdur/app/secrets` through an ACL
entry for the `abdur_auditor` group, so he can enumerate the directory and see
`db-password.txt` with all its metadata.

Reading the *contents* is a separate check against the file's own mode. That
file is `0640 root:abdur_ops` with no ACL at all — abdur_dan is not the owner, is not in
`abdur_ops`, and "other" has no bits — so the `open()` behind `cat` is refused with
`EACCES`. In short: the directory tells you what exists, the file tells you what
you may read, and I granted exactly one of those.

The critical implementation detail is that the `setfacl` on the secrets
directory has **no `-R`**, and there is no default (`-d`) ACL on it either. A
recursive ACL would have propagated `abdur_auditor:r` onto the file and abdur_dan could
`cat` it; a default ACL would silently do the same thing to every secret added
in future.

### Task 3 — Why the sticky bit alone does not stop abdur_carol

The obvious answer is the sticky bit (`chmod +t`), and it is wrong here. The
kernel's sticky check (`check_sticky()` in `fs/namei.c`) lets you unlink a file
if **either** you own the file **or you own the directory**. The brief
deliberately makes abdur_carol the owner of `/srv/abdur/app/backups`, so the sticky bit
exempts her and `rm` succeeds.

What actually stops her is the immutable attribute on the files:

```bash
sudo chattr +i /srv/abdur/app/backups/backup1.tar
```

`rm` then fails with `Operation not permitted` (`EPERM`, not `EACCES`) for
*everyone including root* until `chattr -i` is run, which itself requires
`CAP_LINUX_IMMUTABLE`. I kept the sticky bit as well, because it still does
useful work: it stops other `abdur_ops` members deleting each other's files.

Caveat I checked: `chattr` needs a filesystem that supports the attribute —
ext4 and xfs do, overlayfs and tmpfs do not. On this VPS `/srv` is
`<<FILL: findmnt -no FSTYPE /srv>>`.

### Task 4 — Restart without full sudo

[`configs/sudoers-myapp`](configs/sudoers-myapp) grants `%abdur_devs` a `Cmnd_Alias` of
fully-spelled-out `systemctl` invocations against `abdur-myapp` only, `NOPASSWD`.
Three things it deliberately avoids:

- `NOPASSWD: ALL` — that is just root with extra steps.
- `NOPASSWD: /usr/bin/systemctl` — bare, that permits `systemctl edit sshd`,
  which opens an editor **as root**, and every editor can spawn a shell.
- `NOPASSWD: /usr/bin/systemctl restart *` — the wildcard matches
  `restart sshd` and anything else on the box.

Both `/usr/bin/systemctl` and `/bin/systemctl` are listed because sudo matches
on the path as typed and `/bin` is a symlink on Ubuntu.

Proof (rows 3, 5, 12 of the table): abdur_alice restarts `abdur-myapp`; `sudo -n apt update`
as abdur_alice is refused; abdur_dan is refused entirely because `abdur_auditor` appears nowhere
in the policy. `sudo -l -U abdur_alice` prints the exact allowed list.

---

## A2 — Who is using my port?

### Task 5 — Identifying the process

| Question | Command | Answer |
| --- | --- | --- |
| Which PID | `sudo ss -lptn 'sport = :8180'` | `<<FILL: pid>>` |
| Which binary | `sudo ls -l /proc/<PID>/exe` | `<<FILL: /usr/bin/python3.x>>` |
| Which user | `ps -o user= -p <PID>` / `stat -c %U /proc/<PID>` | `root` |
| When started | `ps -o lstart= -p <PID>` | `<<FILL>>` |
| Full command line | `tr '\0' ' ' < /proc/<PID>/cmdline; echo` | `python3 -m http.server 8180` |

`ps` truncates and `lsof` needs installing; `/proc/<PID>/` is always there and
never lies. `cmdline` is NUL-separated, hence the `tr`.

### Task 6 — Why the output changes with sudo

`ss` and `lsof` do not have a special socket-to-process index to read. To say
*which* process owns a socket they have to walk `/proc/<pid>/fd/` for every
process, `readlink()` each descriptor, and match the `socket:[inode]` targets
against the inodes in `/proc/net/tcp`. `/proc/<pid>/fd/` is `0500` and owned by
that process's user, so an unprivileged user simply cannot open the directories
belonging to root's processes.

So without sudo the socket itself is still listed — the listening table in
`/proc/net/tcp` is world-readable — but the `users:(("python3",pid=...))`
column is blank for anything I do not own, and `lsof -i :8180` prints nothing
at all plus a pile of `Permission denied` warnings. With sudo the same walk
succeeds and the PID, user and command appear. The port-8181 process I started
as my normal user shows its PID **without** sudo, which is the controlled
comparison that proves it is about process ownership and not about ports.

### Task 7 — Manual, systemd, or cron?

How I told them apart:

```bash
systemctl status <PID>          # maps a PID to its cgroup/unit in one step
cat /proc/<PID>/cgroup          # the ground truth underneath that
ps -o ppid= -p <PID>            # parent: a shell? cron? PID 1?
sudo journalctl _PID=<PID>
grep -r 8180 /etc/cron* /var/spool/cron/crontabs/ 2>/dev/null
```

The decisive one is the cgroup. A service lives in
`/system.slice/<name>.service`; a cron job lives under `cron.service`; something
I typed lives in `/user.slice/user-1000.slice/session-N.scope`. On my box the
process was in `<<FILL: paste the cgroup line>>`, so it was
**`<<FILL: started manually from an interactive shell>>`** — its parent was my
own `bash`, and `journalctl` had nothing for it because it was writing to my
terminal, not to the journal.

**If it had been started by systemd, what does `kill -9` do?** Nothing lasting.
systemd is the process's parent, reaps it, sees a non-zero/killed exit, and
`Restart=` brings it straight back with a new PID. You get a port that is free
for a second or two and then taken again by a different PID — the classic "I
killed it and it came back" confusion. Worse, `kill -9` gives the process no
chance to flush or close cleanly, and with `Restart=always` you can end up
fighting the supervisor indefinitely. The correct action is to go one level up
and tell the supervisor: `sudo systemctl stop <unit>` (and `disable` it if it
should not return at boot).

**Killing it properly here.** Since it was a manually started foreground
process, `Ctrl-C` in its own terminal, or `sudo kill <PID>` (SIGTERM — polite,
lets Python's handler run) from another. `kill -9` only if TERM is ignored.
Then:

```bash
sudo ss -lptn 'sport = :8180'   # no output = free
```

<<FILL: paste the empty ss output>>

### Task 8 — "Timed out" vs "connection refused"

They are different failures at different layers, and the difference tells you
where to look:

- **Connection refused** — your SYN arrived and the host answered with a TCP
  RST. Something is reachable and actively saying "nothing is listening here".
  The network path is fine. Causes: the app is bound to `127.0.0.1` instead of
  `0.0.0.0`, so it never sees packets arriving on the public interface; or the
  app is not running; or a firewall configured to REJECT rather than DROP.
- **Timed out** — your SYN went into a black hole and nothing came back at all.
  Something silently dropped the packet. Causes: a cloud security group or
  network ACL that does not allow the port (this is the usual one), `ufw`/
  `iptables` with a DROP policy, or the host being unreachable entirely.

For my case, `curl localhost:8180` works but `curl http://<server-ip>:8180`
from my laptop `<<FILL: timed out / was refused>>`, so the cause was
`<<FILL: e.g. the provider security group only allows 22/80/443>>`.

The diagnosis sequence:

```bash
ss -lntp | grep 8180     # is it 127.0.0.1:8180 or 0.0.0.0:8180 ?
sudo ufw status verbose
# from the laptop:
nc -vz <server-ip> 8180          # refused vs timeout, without curl in the way
```

`ss -lntp` distinguishes the two most likely causes on its own: `127.0.0.1:8180`
means the bind address is wrong (fix the app, `HOST=0.0.0.0`), `0.0.0.0:8180`
means the packet is not reaching the host (fix the firewall / security group).

---

## A3 — The healthcheck script

Script: [`configs/healthcheck.sh`](configs/healthcheck.sh) — config:
[`configs/checks.conf`](configs/checks.conf)

| Requirement | How |
| --- | --- |
| config path arg, default `./checks.conf` | `CONFIG="${1:-./checks.conf}"` |
| skip blanks and `#` | trim, `[ -z "$line" ] && continue`, `case "$line" in \#*)` |
| 3s curl timeout | `--max-time 3 --connect-timeout 3` (both — see below) |
| disk `/` over 80% | `df -P /` + awk on column 5 |
| coloured summary, detailed log | ANSI only when `[ -t 1 ]`; timestamped lines to `/var/log/abdur-healthcheck.log` |
| exit 0 / 1 / 2 | healthy / any failure / config unreadable |
| no concurrent runs | `flock -n` on fd 200 |

Two details that are easy to get wrong:

- **`--max-time` and `--connect-timeout` are not the same budget.**
  `--connect-timeout` only bounds DNS + TCP handshake. A host that accepts the
  connection and then never sends a byte — exactly what my own `/hang` endpoint
  does — sails past it. `--max-time` bounds the whole transfer, which is the
  guarantee the brief actually asks for.
- **Colour is gated on `[ -t 1 ]`.** Otherwise every log line and every piped
  `grep` is full of `\033[0;32m`.

### Task 10 — Break tests

**Break 1: a config file that does not exist.**

```
$ ./healthcheck.sh /nope/nope.conf ; echo "exit=$?"
ERROR config file not found or unreadable: /nope/nope.conf
exit=2
```

Works as specified. I test `-f` **and** `-r` separately, because a file that
exists but is mode `0600 root:root` read by the cron user is a different and
more confusing failure than a missing one, and both must be exit 2 rather than
"zero services checked, all healthy".

**Break 2: a URL that does not resolve** (`configs/checks-broken.conf`).

```
[ OK ] app-1      http://127.0.0.1:3101/healthz   200 in 3ms
[FAIL] bad-dns    http://doesnotexist.invalid/    got 000, expected 200 (curl exit 6: could not resolve host) in 4ms
[FAIL] bad-port   http://127.0.0.1:59999/healthz  got 000, expected 200 (curl exit 7: could not connect) in 0ms
[BAD ] malformed line: this-line-is-malformed
3 of 4 checks FAILED
exit=1
```

No hang, no crash: curl reports `000` with exit 6, the run finishes in well
under a second, the exit code is 1. I map curl's exit codes (6 resolve, 7
connect, 28 timeout) to English, because "expected 200 got 000" on its own does
not tell you whether DNS, the network or the app is at fault.

### Three bugs I only found by running it

These were all invisible on a read-through and obvious on the first execution:

1. **curl was eating the config file.** Inside `while read ... done < "$CONFIG"`
   the loop's stdin *is* the config file, and curl inherits it and consumes the
   rest. The script checked the first service, reported `all 1 checks passed`,
   and silently ignored the other three. Fix: `curl ... < /dev/null`.
2. **`date +%s%N` is GNU-only.** On macOS `%N` is literal and the arithmetic
   blew up with `value too great for base`. Fix: use curl's own
   `%{time_total}` — it is more accurate anyway, since it measures the request
   rather than the shell around it.
3. **A missing `flock` binary read as "lock held".** `if ! flock -n 200` is
   true when `flock` does not exist (exit 127), so the script exited 0 without
   checking anything at all. A monitoring script that silently does nothing is
   worse than one that crashes, so the absence is now a loud warning.

### Task 11 — cron

[`configs/crontab-entry.txt`](configs/crontab-entry.txt). `PATH` is set explicitly in the
crontab because cron's environment is nearly empty — the single most common
reason a script that "works when I run it" does nothing from cron.

```
*/5 * * * * /usr/local/bin/abdur-healthcheck.sh /etc/abdur-healthcheck/checks.conf >/dev/null
```

Evidence: `crontab -l` and `tail /var/log/abdur-healthcheck.log` showing at least two
distinct run timestamps — `evidence/a3-cron.png`.

---

## A4 — systemd

Unit: [`configs/abdur-myapp.service`](configs/abdur-myapp.service)

### Task 13 — The restart limit

`StartLimitIntervalSec=60` + `StartLimitBurst=5` in **`[Unit]`**. On systemd
≥ 230 these are `[Unit]` directives; left in `[Service]` they are ignored and
the service restarts for ever while the unit file *looks* correct.

After six hits on `/crash`:

```
● abdur-myapp.service - abdur-myapp demo service
     Active: failed (Result: start-limit-hit)
systemd[1]: abdur-myapp.service: Start request repeated too quickly.
systemd[1]: abdur-myapp.service: Failed with result 'start-limit-hit'.
```

**Why you want the limit in production.** A crash loop is almost never
self-healing — the usual causes are a bad config, a failed migration, a missing
secret or a dependency that is down, and none of those improve by being retried
200 times a minute. Restarting for ever converts a loud, obvious outage into a
quiet one: the unit reports `activating` forever, the port flaps up and down so
health checks pass intermittently, and the load balancer keeps sending real
traffic into a process that is about to die. Meanwhile the loop burns CPU,
writes gigabytes of identical journal entries, and hammers whatever dependency
it is failing against — a database that is struggling gets a reconnect storm on
top. Reaching a terminal `failed` state is what makes the alert fire, stops the
box being a bad neighbour, and leaves the last real error at the end of the
journal instead of buried 10,000 lines up.

**With `Restart=always` and `StartLimitBurst=0`** the same loop never stops.
`systemctl status` shows `active (running)` with a main PID that changes every
couple of seconds, `NRestarts=` climbs without bound, and journal is a wall of
identical start/exit pairs. Note that *deleting* the StartLimit lines is not the
same as disabling the limit: systemd falls back to its defaults of 5 starts per
10s, which is why `StartLimitBurst=0` is set explicitly.

**How I would notice this in production without watching a terminal:**

- Alert on `NRestarts` — `systemctl show abdur-myapp -p NRestarts` scraped by
  node_exporter's textfile collector, or `systemd_unit_restarts_total`. A rate
  above zero for more than a few minutes is a page.
- Alert on process uptime: `time() - process_start_time_seconds` staying under
  a minute means the process is being replaced constantly.
- The app's own uptime metric resetting to zero repeatedly on the Grafana
  dashboard (Scenario B has exactly this).
- `journalctl -u abdur-myapp -p err --since -15m | wc -l` crossing a threshold.
- Indirectly and most visibly: an error-rate spike in nginx's 502s, because
  every restart drops in-flight connections.

The general rule: `Restart=always` with no limit is defensible **only** when you
also alert on restart count. Without that alert it is a way of hiding outages.

### Task 14 — journalctl

| # | Want | Command |
| --- | --- | --- |
| 1 | Last 10 minutes | `journalctl -u abdur-myapp --since "10 min ago"` |
| 2 | Errors and worse | `journalctl -u abdur-myapp -p err` (`-p err` = priority ≤ 3, so err/crit/alert/emerg) |
| 3 | This boot / previous boot | `journalctl -u abdur-myapp -b 0` / `journalctl -u abdur-myapp -b -1` |
| 4 | JSON | `journalctl -u abdur-myapp -o json-pretty -n 5` (`-o json` for one object per line, which is what you pipe to `jq`) |
| 5 | Follow live | `journalctl -u abdur-myapp -f` then `sudo systemctl restart abdur-myapp` in another terminal |

Two notes: `-p err` takes the priority *and everything more severe*, it is not
an exact match — `-p err..err` if you really want only that level. And `-b -1`
returns "Specified boot ID not found" unless the journal is persistent; that
needs `Storage=persistent` in `/etc/systemd/journald.conf` and
`/var/log/journal` to exist, which is not the default on a minimal Ubuntu
image. `journalctl --list-boots` shows what is actually retained.
On this box: `<<FILL: paste journalctl --list-boots>>`.

### Task 15 — Alive but dead

Watchdog: [`configs/abdur-abdur-myapp-watchdog.sh`](configs/abdur-abdur-myapp-watchdog.sh) +
[`.service`](configs/abdur-abdur-myapp-watchdog.service) + [`.timer`](configs/abdur-abdur-myapp-watchdog.timer),
firing every 30s.

**Why `Restart=on-failure` did not catch it.** `Restart=` is a reaction to a
*process lifecycle event*: systemd only re-evaluates it when the main PID exits,
or is killed by a signal, or a watchdog keepalive it is expecting fails to
arrive. When I hit `/hang` none of those happen. The process stays in the
process table, keeps its main PID, keeps the listening socket open, and the
kernel keeps completing TCP handshakes on its behalf from the accept queue
whether or not userspace ever calls `accept()`. From systemd's point of view
absolutely nothing has changed, so it correctly reports `active (running)` and
does nothing — it is answering "is the process alive?", which is the wrong
question. The only thing that knows the app is broken is something that asks
the app to do work and waits for an answer: an HTTP probe against `/healthz`
with a hard timeout. That is why liveness has to be defined at the application
protocol layer, and it is the same reason Kubernetes has a liveness probe on
top of a restart policy rather than relying on the restart policy alone.

The timer is the external version of that probe. The built-in alternative is
systemd's native watchdog (`WatchdogSec=30` plus `sd_notify(WATCHDOG=1)` from a
timer inside the app), which is stronger because the keepalive comes from the
app's own event loop — if the loop is blocked, the ping stops, and systemd acts.
I used the timer because it needs no library in the app and it tests the same
path a real user takes (a real HTTP request through the real socket) rather
than trusting the app's opinion of itself.

`AccuracySec=1s` is set on the timer: systemd's default `AccuracySec=1min`
batches timers together to let the CPU idle, which turns a "30 second" watchdog
into one that fires whenever it feels like it.

Evidence with timestamps (`evidence/a4-watchdog.png`): `/hang` at T, watchdog
logs `UNHEALTHY` at T+`<<FILL>>`s, `systemd[1]: abdur-myapp.service: Scheduled
restart job` immediately after, `/healthz` answering again by T+`<<FILL>>`s.

---

## A5 — nginx

Config: [`configs/nginx-myapp.conf`](configs/nginx-myapp.conf)

### Task 16 — Proxy headers

Without `proxy_set_header`, `/whoami` reports `remoteAddress: "127.0.0.1"` for
every request, because nginx is the peer that opened the TCP connection — the
app is not lying, it genuinely has no other information. `X-Real-IP` and
`X-Forwarded-For` carry the original address as data at the application layer.

Note for anything security-relevant: `$proxy_add_x_forwarded_for` **appends** to
whatever the client sent, so a client can pre-seed the header with any value it
likes. Only the last entry — the one nginx added — is trustworthy. Rate limiting
or IP allow-lists that read the first entry are trivially spoofable.

Evidence: `evidence/a5-whoami-from-laptop.png`, showing my real home IP in
`x-real-ip` while `remoteAddress` is `127.0.0.1`.

### Task 17 — Load balancing algorithms

100 requests, `curl -s http://localhost/ | sort | uniq -c`:

| Algorithm | 3101 | 3102 | What it does |
| --- | --- | --- | --- |
| round robin (default) | `<<FILL: ~50>>` | `<<FILL: ~50>>` | strict alternation, blind to load |
| `least_conn` | `<<FILL>>` | `<<FILL>>` | picks the backend with fewest active connections |
| `ip_hash` | `<<FILL: 100>>` | `<<FILL: 0>>` | hashes the client IP; one client = one backend |

**Round robin** alternates regardless of what each backend is doing. With
uniform, fast requests that is optimal and the split is 50/50. It falls apart
when request cost varies: it will keep handing work to a backend that is stuck
on a 45-second `/slow` request, because "it is your turn" is the only input.

**least_conn** routes to whichever backend currently has the fewest open
connections, which is a cheap proxy for "least busy". With uniform requests it
looks identical to round robin; with mixed costs it is strictly better, and it
is the right default once an endpoint like `/slow` exists.

**ip_hash** hashes the client address so the same client always reaches the same
backend — sticky sessions for apps that keep state in memory. The cost is that
distribution is only as even as your client population: my test loop comes from
a single IP, so **all 100 requests land on one backend and it looks completely
broken**. That is the honest failure mode to show, and it is exactly what
happens in production when all your traffic arrives from one NAT gateway or one
CDN egress range.

### Task 18 — Passive health checks and failover

Measured from `evidence/a5-failover-loop.txt`.

| | `max_fails=3 fail_timeout=10s` | `max_fails=1 fail_timeout=30s` |
| --- | --- | --- |
| Requests failed before 3102 was ejected | `<<FILL>>` | `<<FILL>>` |
| Time from stopping 3102 to a clean stream | `<<FILL>>s` | `<<FILL>>s` |
| Time from restarting 3102 to traffic returning | `<<FILL>>s` | `<<FILL>>s` |
| Periodic single failures while it stayed down | `<<FILL>>` | `<<FILL>>` |

**Why those numbers.** nginx open source does not poll anything. A backend is
marked down only after `max_fails` failed *proxied requests* inside a
`fail_timeout` window — so failures have to be paid for with real traffic. With
round robin at ~2 req/s, roughly every other request goes to the dead backend,
so 3 failures cost about 6 requests ≈ 3 seconds. `proxy_next_upstream` masks
some of those from the client by retrying on the live backend, which is why the
client-visible failure count is lower than the internal one.

`fail_timeout` does double duty: it is both the window in which failures are
counted *and* the length of the ban. So a backend ejected with
`fail_timeout=10s` is retried 10 seconds later; if it answers it returns to
rotation immediately, and if not it is banned for another 10s. That produces the
single isolated failure every ~10s while the backend stays down — the probe
request is a real user's request. Traffic therefore returns within one
`fail_timeout` of the backend recovering, not instantly.

With `max_fails=1 fail_timeout=30s` the trade flips: ejection after a single
failure (fewer users see an error) but a 30-second ban and 30-second retry
interval, so recovery is much slower and one transient blip takes a healthy
backend out for half a minute. That is the real tension — `max_fails=1` is
aggressive about protecting users and dangerous under packet loss, since a
single flap can eject backends until nothing is left. When every backend is
marked down nginx clears the flags and tries them all again rather than
returning 502 to everyone, which is a deliberate and slightly surprising safety
valve.

This is also the honest limitation of open-source nginx: no active probes
(`health_check` is nginx Plus), so a backend is never known-good until a real
user pays to find out. Alternatives: put HAProxy in front, or run
`nginx-module-vts`/`ngx_http_upstream_check_module`.

### Task 19 — The 504, and why raising the timeout is the wrong fix

With `proxy_read_timeout 5s`: `504 Gateway Time-out` after ~5s.
With `proxy_read_timeout 60s`: `200` after ~45s. Both in
`evidence/a5-504.png` and `evidence/a5-504-fixed.png`.

**Why raising it is usually wrong.** The timeout is not the problem; it is the
alarm. Raising it silences the alarm and leaves the 45-second request in place,
and now that request holds resources for 45 seconds at *every* layer instead of
5.

Follow the resource. nginx handles connections cheaply — a worker holds an
idle-ish connection for a few KB of memory, so 500 concurrent slow requests is
survivable *for nginx*, though it will exhaust `worker_connections` (default
768 per worker on Ubuntu) faster than people expect once you count the upstream
socket, which consumes a second slot per request. But nginx is not the
constraint. Behind it, each of those 500 requests is pinned to something far
more expensive: a Node event-loop slot with its timers and buffers, or in a
thread-per-request stack an entire worker thread, and almost always a database
connection out of a pool of maybe 20. At 500 concurrent 45-second requests the
pool is exhausted in the first second and **every other endpoint on the site
starts timing out too** — the login page, the health check, everything. That is
the actual failure: one slow endpoint takes the whole service down, and a
60-second timeout means the queue takes 60 seconds to drain after the load
stops, so recovery is slow even after the burst ends. Meanwhile the user gave up
at 10 seconds and hit refresh, so the work is discarded anyway and their retry
adds another 45-second request on top.

**What I would do instead, roughly in order:**

1. **Make it asynchronous.** `POST /export` returns `202 Accepted` with a job
   id in under 50ms, a worker off a queue (Sidekiq/Celery/BullMQ) does the 45
   seconds of work, and the client polls `GET /jobs/:id` or gets a webhook. The
   HTTP request stops being the unit of work. This is the correct fix for
   almost every real 45-second endpoint.
2. **Make it fast.** 45 seconds is usually a missing index, an N+1, or an
   unbounded result set — Scenario B has all three deliberately. Measure before
   assuming it is irreducible.
3. **Cache or precompute** if the result is the same for many users.
4. **Stream** — send bytes as they are produced so the read timeout never
   trips and the user sees progress.
5. **Bulkhead it.** If the slow endpoint must stay synchronous, give it its own
   upstream pool and its own connection limits (`limit_conn`) so it can only
   ever starve itself, never the login page.
6. **Fail fast and shed load.** A short timeout plus a clear 503 is kinder than
   a request that hangs for a minute and then fails anyway.

Raising the timeout is defensible only as a deliberate, temporary, documented
stopgap for a known-bounded internal endpoint with a ticket attached — and
scoped to that one `location`, never globally, which is why my `/slow` block is
separate from `/`.

### Task 20 — Rate limiting

`limit_req_zone $binary_remote_addr zone=api_limit:10m rate=10r/s` +
`limit_req zone=api_limit burst=20 nodelay` on `/api/`.

50 rapid requests: `<<FILL: e.g. 21x 200, 29x 429>>` — `evidence/a5-ratelimit.png`.

Details that matter:

- **`$binary_remote_addr`, not `$remote_addr`** — 4 bytes instead of ~15 per
  entry, so a 10 MB zone holds roughly 160,000 addresses instead of a fraction
  of that.
- **`nodelay`** — without it nginx *queues* the burst and drips it out at
  10r/s, so all 50 requests eventually return 200 and the proof shows nothing.
  With it, excess requests are rejected immediately.
- **`limit_req_status 429`** — the default is 503, which tells the client
  "server is broken" instead of "you are going too fast", and 503 makes
  well-behaved clients and CDNs retry, which is the opposite of the goal.
- The counter is per nginx worker's shared zone and keyed on the client IP, so
  once nginx sits behind a CDN this must be paired with `set_real_ip_from` /
  `real_ip_header`, otherwise every visitor shares one bucket.
