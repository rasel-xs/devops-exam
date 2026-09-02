# Viva preparation — Scenario A

Questions a marker can ask straight from the files in `evidence/`, with the
answer and **where in my own output it is proved**. The brief says the viva is
about explaining *and modifying* my own work, so each section ends with a
"change it live" drill.

> If I am asked something I do not know, the honest answer is: *"I did not test
> that. What I did test is X, and here is the output."* Guessing is worse than
> saying so — three of the findings in this submission came from a prediction
> of mine being wrong.

---

## A1 — `evidence/a1-proof-table.txt`

### Q: dan can `ls` the secrets folder but not `cat` the file. Why?

Two independent permission checks. On a **directory**, `r` means "read the list
of names" and `x` means "resolve a name to its inode" — which is what `ls -l`
needs to `stat()` each entry. dan has `r-x` on `/srv/abdur/app/secrets` through
an ACL entry for the `abdur_auditor` group, so he can enumerate it.

Reading the *contents* is checked against the file's own mode. That file is
`0640 root:abdur_ops` with **no ACL at all** — dan is not the owner, not in
`abdur_ops`, and `other` has nothing. So `open()` is refused with `EACCES`.

**Proved by the two `getfacl` outputs side by side:**

```
# file: /srv/abdur/app/secrets          <- the DIRECTORY
group:abdur_auditor:r-x                  <- dan's rule is here

# file: .../secrets/db-password.txt      <- the FILE
user::rw-
group::r--
other::---                               <- no auditor entry at all
```

### Q: Show me the one command that would have broken this.

```bash
setfacl -R -m g:abdur_auditor:rX /srv/abdur/app/secrets
```

The `-R`. It would have propagated the ACL onto `db-password.txt`, dan could
`cat` it, and `ls -l` would show a `+` next to the file — which the brief's
expected output does not have. A default ACL (`-d`) would do the same to every
secret added later.

### Q: Why does `ls -l` show a `+` on `backup1.tar` but not on `db-password.txt`?

The `+` means an ACL is present. The backups directory got
`setfacl -R -m g:abdur_auditor:rX` so dan can read backups — that is intended.
The secrets *file* was deliberately left with no ACL. The `+` is the visible
difference between "I gave access here" and "I did not".

### Q: Why is carol in two groups?

Primary `abdur_ops`, supplementary `abdur_devs`. The brief says carol can do
"everything devs can do, plus…". `/srv/abdur/app/src` is `2770 root:abdur_devs`
with nothing for `other`, so without devs membership she could not enter the
source directory at all, could not read logs, and — since sudoers grants
`%abdur_devs` — could not restart the service either.

**Proved by:** `uid=1030(abdur_carol) gid=1041(abdur_ops)
groups=1041(abdur_ops),1040(abdur_devs)`

### Q: carol's `rm` said `Operation not permitted`, dan's `cat` said `Permission denied`. Why different?

Different errno, different mechanism:

| Message | errno | Cause |
| --- | --- | --- |
| `Permission denied` | `EACCES` | a permission bit or ACL refused it |
| `Operation not permitted` | `EPERM` | a **file attribute** refused it |

carol's permissions were fine — she owns the directory and has write on it.
What stopped her is `chattr +i` on the file. The different message is the
proof that it was the immutable flag and not a mode.

### Q: Why not just use the sticky bit?

Because the kernel's sticky check allows the unlink if you own the file **or
you own the directory** — and the brief deliberately makes carol the owner of
the directory, so she is exempt. `/tmp` works because *root* owns `/tmp` and
you are not root. I kept the sticky bit anyway (mode `3770`), because it still
stops other `abdur_ops` members deleting each other's files.

### Q: What is `2770`?

`2` = setgid, then `rwx` owner, `rwx` group, `---` other. setgid matters
because carol's primary group is `abdur_ops`: without it, a file she creates in
`src/` would be owned by `abdur_ops` and bob could not edit it. With it, new
files inherit `abdur_devs`.

### 🔧 Change it live
- *"Let bob read the secret."* → `setfacl -m u:abdur_bob:r /srv/abdur/app/secrets/db-password.txt`
  (and note that `ls -l` now shows a `+` on it).
- *"Let carol delete backup2.tar."* → `chattr -i /srv/abdur/app/backups/backup2.tar`
- *"Let alice run `systemctl restart nginx` too."* → add
  `/usr/bin/systemctl restart nginx` to the `ABDUR_MYAPP_CTL` alias, then
  `visudo -cf` **before** installing.

---

## A2 — `evidence/a2-session.txt`

### Q: Why is the Process column empty for 8180 but filled for 8181?

`ss` has no socket→process index to read. To name the owner it walks
`/proc/<pid>/fd/` for every process, `readlink()`s each descriptor, and matches
the `socket:[inode]` targets against `/proc/net/tcp`. `/proc/<pid>/fd/` is
`0500` and owned by that process's user, so `abdur_alice` cannot open root's.
She *can* see her own process on 8181, which is the controlled comparison — it
proves the issue is process ownership, not the port.

**Proved by:**
```
dr-x------ 2 root root /proc/104146/fd
ls: cannot open directory '/proc/104146/fd': Permission denied
  sl local_address ... uid ... inode        <- but /proc/net/tcp IS readable
```

Note alice can even see from `/proc/net/tcp` that the socket belongs to uid 0 —
what she cannot do is map it to a PID.

### Q: How did you know it was started by hand and not by systemd or cron?

Four signals, all agreeing, with the cgroup being decisive:

| Signal | Value |
| --- | --- |
| cgroup | `/user.slice/user-0.slice/session-985.scope` |
| cgroup of a real service, for contrast | `/system.slice/abdur-myapp.service` |
| parent | `bash` |
| `systemctl status <pid>` | `Session 985 of User root`, `Transient: yes` |
| cron | nothing matching the port |

`Transient: yes` means that scope has no unit file on disk — systemd created it
when the SSH session opened. Parent alone is not enough: when I re-ran the test
from a script the parent became the script, but the cgroup did not change.

### Q: What happens if you `kill -9` a systemd-managed process?

It comes straight back with a new PID. I did it rather than assert it:

```
PID before kill : 102662
>>> kill -9 102662
PID after 3s    : 103465
unit state      : active
```

systemd is the parent, reaps it, sees `status=9/KILL`, and `Restart=on-failure`
schedules a restart. The right move is to tell the supervisor:
`systemctl stop`, and `disable` if it should not return at boot.

### Q: Why 264 ms for one failure and 6005 ms for another?

- **Refused (264 ms)** — the SYN reached the host, nothing was listening on
  that address, the kernel replied with a RST. One round trip and curl gives
  up. Cause is local to the host: wrong bind address, or nothing running.
- **Timed out (6005 ms)** — the SYN was silently dropped by a firewall rule.
  Nothing came back at all, so TCP retransmitted until my `--max-time 6`
  expired. Cause is on the path: firewall, security group, network ACL.

**Refused = someone said no. Timeout = nobody said anything.**

### Q: Ports 8182 and 9999 both said "refused". How would you tell them apart?

From outside you cannot — "not running" and "bound to the wrong address" look
identical. `ss -lntp` on the server separates them: `127.0.0.1:8182` means fix
the bind address, `0.0.0.0:8182` with no response means fix the firewall.

### 🔧 Change it live
- *"Make 8182 reachable."* → restart it with `--bind 0.0.0.0`, confirm with
  `ss -lntp`.
- *"Find what holds port 22 and when it started."* →
  `ss -lntpH 'sport = :22'`, then `readlink -f /proc/<pid>/exe`,
  `ps -o lstart= -p <pid>`, `cat /proc/<pid>/cgroup`.

---

## A3 — `evidence/a3-session.txt`

### Q: Walk me through your exit codes.

`0` healthy, `1` at least one service failed (or a malformed config line), `2`
config missing **or unreadable**. A disk warning alone stays `0` because the
brief calls it a warning, not a failure — and I say so explicitly rather than
leaving it ambiguous.

### Q: You added a test the brief did not ask for. Why?

The brief asks for "a config file that does not exist". Under cron the failure
that actually happens is a file that *exists* with the wrong owner or mode. Both
must be exit 2 — the dangerous alternative is "0 services checked, all
healthy". That is why the guard tests `-f` **and** `-r`.

**And that test found a real bug.** Running as `abdur_alice` the script could
not open `/var/lock/abdur-healthcheck.lock`, exited 1 *before reaching the
config check*, and checked nothing at all. Under cron as any non-root user it
would have been permanently silent. It now warns loudly and continues without
a lock — the same policy I already had for a missing `flock` binary.

### Q: Prove the concurrency guard works.

```
20:14:41  first copy starts (slow.conf, ~9s of work)
20:14:43  second copy starts, cannot take the lock, exits 0
20:14:44  blackhole-1 fails after 3003ms
20:14:47  blackhole-2 fails after 3009ms
20:14:50  blackhole-3 fails after 3005ms
20:14:51  first copy ends
```

`slow.conf` points at unrouted `10.255.255.x` so each check sits for the full
3 s connect timeout, giving a wide enough window to start a second copy by hand.

### Q: Why does the second copy exit **0** rather than an error?

A second copy declining to run is normal operation, not a fault. If it exited
non-zero, cron would email an alert every five minutes about something working
exactly as designed — and alerts nobody trusts get muted.

### Q: Why is the colour gated on `[ -t 1 ]`?

So a real terminal gets colour and a pipe or a log file does not. Otherwise
every log line and every `grep` is full of `\033[0;32m`. The brief asks for both
a coloured summary and a log file; that one test satisfies both.

### Q: Why both `--max-time` and `--connect-timeout`?

`--connect-timeout` bounds only DNS + TCP handshake. A host that accepts the
connection and then says nothing sails past it — which is exactly what my own
`/hang` endpoint does. `--max-time` bounds the whole transfer, which is the 3
second guarantee the brief actually asks for.

### 🔧 Change it live
- *"Warn at 60% disk instead of 80%."* → `DISK_THRESHOLD=60`.
- *"Add a check for nginx on port 80."* → one line in `checks.conf`:
  `nginx-80|http://127.0.0.1/|200`.
- *"Make it exit 2 on a disk warning too."* → move the disk branch into the
  failure count, and say why that is a design change, not a bug fix.

---

## A4 — `evidence/a4-task13-*.txt`, `a4-task14-*.txt`, `a4-task15-*.txt`

### Q: Why are `StartLimitIntervalSec` and `StartLimitBurst` in `[Unit]`?

Since systemd 230 they are `[Unit]` directives. Put them in `[Service]` and
systemd **parses the file without complaint and ignores them** — the unit looks
correct and the service restarts for ever. This box runs systemd 255.

### Q: Your status line says `Result: exit-code`, not `start-limit-hit`. Explain.

`Result` records the last thing that actually failed — the process exiting 1.
The start-limit decision is reported in the journal instead:

```
20:27:39 Scheduled restart job, restart counter is at 5.
20:27:39 Start request repeated too quickly.
20:27:39 Failed to start abdur-myapp.service
```

I expected `start-limit-hit` and it was not what the box produced. Both things
the brief asks for are present, in two different places.

### Q: `After=postgresql.service` is in your unit and postgres is not installed. Why does it start?

`After=` is **ordering only** — "if both are being started, postgres first".
Nothing to wait for means nothing to wait for. `Requires=` would have made the
service refuse to start. I deliberately did not use it: if the database is
down, I would rather the app run and report unready than not run at all, since
a stopped app cannot even serve an error page.

### Q: Why did `Restart=always` report `Result: success` after six crashes?

Because by systemd's definition it succeeded — it was asked to keep a process
running and it did. That is the danger: any monitoring that asks "has this unit
failed?" gets **no**, while the app dies every two seconds, the port flaps, and
the load balancer keeps sending real traffic to it. A loud outage becomes a
quiet one.

### Q: Why is deleting the StartLimit lines not the same as disabling the limit?

systemd falls back to its defaults of 5 starts per 10 s, so the service still
gives up and you conclude the setting does not work. `StartLimitBurst=0`
disables it explicitly.

### Q: `journalctl -b -1` failed. Is your journal misconfigured?

No — and this is where most people guess wrong. The usual cause is a volatile
journal, but here:

```
$ ls -d /var/log/journal
/var/log/journal                  <- persistent storage IS enabled

$ journalctl --list-boots
  0 b8babff2... Thu 2026-08-27 16:00:30 CEST  Wed 2026-09-02 20:32:23 CEST
```

One boot recorded. The VPS has been up since 27 August and has never rebooted,
so there is no previous boot to show. `--list-boots` is what distinguishes the
two causes.

### Q: Why is `-p err` not an exact level?

It is a maximum: err and everything more severe. Counting lines on my own
journal proves it — `err` 1, `warning` 17, `info` 97. They could not nest like
that if it were an exact match. `-p err..err` is the exact form.

### Q: Why did `Restart=on-failure` not catch `/hang`?

`Restart=` reacts to a process lifecycle event — the main PID exiting, being
signalled, or a watchdog keepalive failing. None happened. The process stayed
alive, kept its PID, kept the listening socket, and the kernel kept completing
handshakes on its behalf.

```
state    : active
main pid : 228253   (unchanged)
curl --max-time 5 /healthz : TIMED OUT after 5s (curl exit 28)
LISTEN 0 511 0.0.0.0:3100  users:(("node",pid=228253,fd=24))
```

`Send-Q 511` is the kernel's accept backlog filling up while userspace never
calls `accept()`. systemd is answering "is the process alive?", which is the
wrong question. Only something that asks the app to do work and waits can tell.

### Q: How long does your watchdog take to notice, worst case?

Measured recovery was **30 seconds**. The worst case is **35 s** — 30 s timer
interval plus the 5 s curl timeout before a restart even begins. Tightening it
means more probe traffic and more risk of restarting a merely-slow app. That is
the same trade Kubernetes exposes as `periodSeconds` / `timeoutSeconds`.

### Q: Why `AccuracySec=1s` on the timer?

systemd defaults to `AccuracySec=1min` and batches timers to let the CPU idle.
On a 30 second watchdog that lets it drift past a minute, which looks exactly
like "my watchdog does not work".

### 🔧 Change it live
- *"Probe every 10 seconds."* → `OnUnitActiveSec=10s`, `daemon-reload`,
  `restart` the **timer**, verify with `systemctl list-timers`.
- *"Allow 10 restarts per 5 minutes."* → `StartLimitIntervalSec=300`,
  `StartLimitBurst=10` in `[Unit]`.
- *"Make it refuse to start without postgres."* → `Requires=postgresql.service`,
  and explain the trade you just accepted.

---

## A5 — `evidence/a5-task18-run*.txt`, `a5-task19-20.txt`, `a5-task16-whoami.txt`

### Q: Your client saw 0 failures but nginx logged 16. Which is the real number?

Both, measuring different things. `proxy_next_upstream error timeout http_502
http_503 http_504` makes nginx retry a failed request on the healthy backend, so
the client never sees it. Reporting only the client view would give "nothing
broke", which is wrong. The failures are in
`/var/log/nginx/abdur-myapp.error.log`.

### Q: Why 16 failures and not 3, when `max_fails=3`?

`max_fails` is counted **per worker process**. An upstream without a `zone`
directive keeps its peer state in each worker's own memory.

```
$ grep '20:58:' error.log | grep -oP '#\K[0-9]+' | sort | uniq -c
      4 237233
      4 237234
      4 237235
      4 237236
```

Four workers × (3 `connect() failed` + 1 `temporarily disabled`) = 16. The
consequence: with four workers and `max_fails=3`, **up to twelve real requests**
can hit a dead backend before every worker has ejected it. That scales with
`worker_processes`, which the directive name does not hint at.

### Q: You predicted 15 s recovery in run 2 and got 5.6 s. What happened?

Same per-worker state. Only three of the four workers ever sent a request to
3102 while it was down:

```
workers running   : 241623  241625  241626  241627
workers in the log: 241623  241625  241626           <- 241627 never saw a failure
```

Worker 241627 never marked it failed, so it never banned it, and routed to 3102
as soon as it came back — without waiting for anyone's `fail_timeout` to expire.
So "the backend is ejected" is a per-worker fact, and recovery is as fast as the
most optimistic worker. `zone upstream_name 64k;` puts that state in shared
memory and makes it uniform — which is why the directive exists.

### Q: Why did `ip_hash` give 97/3 the first time and 100/0 the second?

`systemctl reload nginx` does not kill the old workers; it lets them drain
their connections while new ones start. My loop began immediately after the
reload, so the first few requests were served by old workers still running the
previous `least_conn` config. Re-running after the workers had cycled gave
exactly 100/0. General lesson: a measurement taken seconds after a reload can be
measuring the old configuration.

### Q: Three requests all went to 3101 and it looked broken. Why?

Round-robin state is also per worker, and each worker's *first* request goes to
the first upstream. With four workers and three requests you can easily see one
backend three times. 100 requests came out 50/50.

### Q: What did the `/slow` 504 cost you beyond the failed request?

It ejected a healthy backend:

```
[warn] upstream server temporarily disabled while reading response header
       upstream: "http://127.0.0.1:3101/slow"
```

The timeout counted as a failure against `max_fails`. `proxy_next_upstream off`
on that location stops the request being retried elsewhere; it does not stop the
failure being counted. With `max_fails=1`, one slow request costs half the
capacity for `fail_timeout` seconds. I did not know this before measuring it.

### Q: Why is raising `proxy_read_timeout` the wrong fix?

The timeout is the alarm, not the problem. Follow the resource: nginx holds
connections cheaply, but each of those requests pins a Node event-loop slot and
a database connection from a pool of ~10. At high concurrency the pool is
exhausted in seconds and **every other endpoint starts timing out too** — one
slow endpoint takes the whole service down. A 60 s timeout also means the queue
takes 60 s to drain after the load stops. Plus, as measured above, the timeouts
eject healthy backends.

The fixes in order: make it asynchronous (202 + job id + poll), make it fast
(measure first), cache it, stream it, bulkhead it into its own upstream pool
with `limit_conn`, or fail fast with a clear 503. Raising the timeout is
defensible only as a documented temporary stopgap scoped to one `location` —
which is why my `/slow` block is separate from `/`.

### Q: 29 requests got through, not 20. Why?

`burst=20` allows 20 immediately, and the 50 requests took about a second,
during which `rate=10r/s` refilled roughly 9 more. 20 + 9 = 29. The arithmetic
matching is what tells you the limiter is configured as intended.

### Q: How do you know it is limiting *rate* and not just capping requests?

I ran a control: the same endpoint, 20 requests with a 0.2 s gap, which is
inside the 10r/s budget. Result: `20 404`, **zero** 429s. A naive "reject after
the 21st" would have rejected these too.

### Q: Why `limit_req_status 429` instead of the default?

The default is 503, which tells the client "the server is broken" and makes
well-behaved clients and CDNs **retry** — the opposite of what a rate limiter
wants. 429 says "you are going too fast".

### Q: Why is `limit_req_status` in your `server{}` block and not next to the zone?

Because putting it at http level broke the whole config on this shared VPS:

```
[emerg] "limit_req_status" directive is duplicate in .../abdur-myapp:56
nginx: configuration file test failed
```

Every file in `sites-enabled/` is included into the same `http{}` block, another
student already sets it there, and that directive may appear only once per
context. This is not a name collision — prefixing does not help, because the
*directive itself* must be unique. Both it and `limit_req_log_level` are valid
in `server{}`, so they live there where they cannot break anyone else's site.
`nginx -t` caught it; a direct `reload` would have taken down nginx for
everyone on the box.

### Q: Your app reports `remoteAddress: 127.0.0.1`. Is that a bug?

No — the app is not lying, it has no other information. nginx is the peer that
opened the TCP connection. `X-Real-IP` and `X-Forwarded-For` carry the original
address as application-layer data.

Security caveat: `$proxy_add_x_forwarded_for` **appends** to whatever the client
sent, so a client can pre-seed the header with anything. Only the last entry —
the one nginx added — is trustworthy. Rate limiting or IP allow-lists that read
the first entry are trivially spoofable.

### Q: `x-real-ip` said 103.126.60.85 but `api.ipify.org` said .87. Explain.

Same `/24`. My ISP NATs customers behind a pool of public addresses, so
different connections can leave via different ones. This is the same fact that
makes `ip_hash` degenerate and per-IP rate limiting approximate: an "IP" is
frequently not one user, and sometimes not even one connection from one user.

### 🔧 Change it live
- *"Rate limit to 5 requests a second with no burst."* →
  `rate=5r/s`, `limit_req zone=abdur_api_limit;`, `nginx -t`, reload, re-run
  the 50-request loop.
- *"Make the upstream state shared between workers."* → add
  `zone abdur_backends 64k;` inside the `upstream` block, then re-run the
  failover test and show the error count drop from 16 to 4.
- *"Add a third backend."* → `systemctl enable --now abdur-myapp@3103`, add
  `server 127.0.0.1:3103 ...` to the upstream, `nginx -t`, reload, re-run the
  100-request distribution.
