# Scenario A — Answers

**Exam token:** `root-vmi3536696-1788282556-1536d427`
**Server:** `169.58.246.108` — Ubuntu 24.04.4 LTS

> **Shared machine.** This VPS is also used by other students. Unprefixed
> `alice`/`bob`/`carol`/`dan`, the groups `devs`/`ops`/`auditor` and `/srv/app`
> already existed and belong to someone else, so every identity, path, unit,
> port and global config name in my submission is prefixed `abdur`. Details in
> the table below.

> Every number in this document was measured on the server named above between
> 2026-09-01 and 2026-09-02. Transcripts for each task are in `evidence/`,
> recorded with `script(1)` and carrying the exam token on the first line.

---

## A1 — Team access

Everything is created by [`configs/setup-users.sh`](configs/setup-users.sh) and proved by
[`configs/verify-a1.sh`](configs/verify-a1.sh), whose full output is in
[`evidence/a1-proof-table.txt`](evidence/a1-proof-table.txt).

### Task 1 — Users, groups, ownership and ACLs

Created by [`configs/setup-users.sh`](configs/setup-users.sh); the model is the
table below, and the proof is the check run that follows it.

#### Result

`configs/verify-a1.sh` on 2026-09-01: **PASS=12 FAIL=0** — full output in
[`evidence/a1-proof-table.txt`](evidence/a1-proof-table.txt).

Two error messages in that output are worth separating, because they look
similar and mean different things:

- check 4/10/11 — `Permission denied` (`EACCES`): a permission bit or an ACL
  refused the access.
- check 8 — `Operation not permitted` (`EPERM`): carol's permissions were fine;
  the *file attribute* `chattr +i` refused it. That distinction is the proof
  that the immutable flag, not the sticky bit, is what stops her.

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
ext4 and xfs do, overlayfs and tmpfs do not. On this VPS `/srv` is **ext4**, which supports it (`findmnt -no FSTYPE /srv`).

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

Full session transcript: [`evidence/a2-session.txt`](evidence/a2-session.txt).
The task 8 half was run **from my laptop rather than on the box**, because
"timed out" and "connection refused" are indistinguishable from localhost —
that transcript is
[`evidence/a2-task8-from-laptop.txt`](evidence/a2-task8-from-laptop.txt).

### Task 5 — Identifying the process

| Question | Command | Answer |
| --- | --- | --- |
| Which PID | `ss -lptn 'sport = :8180'` | `103178` |
| Which binary | `readlink -f /proc/103178/exe` | `/usr/bin/python3.12` |
| Which user | `ps -o user= -p <PID>` / `stat -c %U /proc/<PID>` | `root` |
| When started | `ps -o lstart= -p 103178` | `Tue Sep 1 20:50:59 2026` |
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
I typed lives in `/user.slice/user-1000.slice/session-N.scope`. On my box the python process was in:

```
0::/user.slice/user-0.slice/session-985.scope
```

and my own service, for comparison, was in:

```
0::/system.slice/abdur-myapp.service
```

so the mystery process was **started manually from an interactive shell**. Four
independent signals agreed, which is what makes the answer safe rather than a
guess:

| Signal | Result |
| --- | --- |
| cgroup | `session-985.scope` — a login session, not a unit |
| parent | `-bash` |
| `systemctl status 103178` | `Session 985 of User root`, `Transient: yes` |
| `grep -rn 8180 /etc/cron*` | nothing |

`Transient: yes` is the giveaway: that scope has no unit file on disk, systemd
created it on the fly when I opened the SSH session.

**If it had been started by systemd, what does `kill -9` do?** Nothing lasting —
and I proved it rather than asserting it, by doing exactly that to my own
service:

```
kill korar AGE  PID : 102662
>>> kill -9 102662
3 second PORE   PID : 103465
service ekhon       : active
```

The journal narrates the whole decision:

```
21:05:15 systemd[1]: abdur-myapp.service: Main process exited, code=killed, status=9/KILL
21:05:15 systemd[1]: abdur-myapp.service: Failed with result 'signal'.
21:05:17 systemd[1]: abdur-myapp.service: Scheduled restart job, restart counter is at 1.
21:05:17 systemd[1]: Started abdur-myapp.service
21:05:17 abdur-myapp[103465]: listening on 0.0.0.0:3100 (pid 103465)
```


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

```
--- AGE ---
LISTEN 0 5 0.0.0.0:8180 0.0.0.0:* users:(("python3",pid=103178,fd=3))
>>> kill 103178   (SIGTERM)
[1]-  Terminated   nohup python3 -m http.server 8180
--- PORE ---
  port 8180 EKHON FAKA
```

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

**What I measured.** This VPS has `ufw` inactive, and `iptables -L INPUT` shows
`policy ACCEPT` with exactly one rule — `DROP tcp dpt:8080`, added by another
student on this shared box. That handed me both failure modes to compare
without touching the firewall myself. Four requests from my laptop:

| Port | Server-side state | Result from laptop | Time | curl exit |
| --- | --- | --- | --- | --- |
| 8180 | listening on `0.0.0.0` | `200 OK` | 0.44 s | 0 |
| 8182 | listening on `127.0.0.1` only | `Failed to connect` | **0.26 s** | 7 |
| 8080 | listening, but a `DROP` rule | `Connection timed out` | **6.01 s** | 28 |
| 9999 | nothing listening | `Failed to connect` | 0.22 s | 7 |

The timing is the physical signature of the difference, and the gap is ~23x:

- **8182 and 9999** — the SYN reached the host. The kernel found nothing
  listening on that address and replied with a RST immediately, so curl gave up
  after a single round trip.
- **8080** — the SYN was silently discarded by the DROP rule. Nothing came back
  at all, so TCP retransmitted and curl sat there until my `--max-time 6`
  expired.

Note what 8182 and 9999 have in common: seen from outside, **"the app is not
running" and "the app is bound to the wrong address" are indistinguishable**.
Only `ss -lntp` on the server separates them — which is exactly why that is the
first command to run rather than the last.

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

Full transcript: [`evidence/a3-session.txt`](evidence/a3-session.txt).

**Break 1: a config file that does not exist.**

```
ERROR config file not found or unreadable: /nope/does-not-exist.conf
exit code = 2
```

**Break 1b: a config file that EXISTS but is unreadable.** I added this case
myself — the brief only asks for "missing", but under cron the failure that
actually happens is a file that exists with the wrong owner or mode. Both must
be exit 2, never "0 services checked, all healthy", which is why the guard
tests `-f` *and* `-r` separately.

Run as `abdur_alice` against a mode-000 file:

```
warning: cannot open lock file /var/lock/abdur-healthcheck.lock -- running WITHOUT a concurrency lock
warning: cannot write /var/log/abdur-healthcheck.log, logging to stderr
[WARN] cannot open lock file /var/lock/abdur-healthcheck.lock (running as abdur_alice) -- no lock held
ERROR config file not found or unreadable: /tmp/abdur-unreadable.conf
exit code = 2
```

Three degradations at once, and the script still did its job and returned the
right code. **This test found a real bug** — see below.

**Break 2: a URL that does not resolve at all.**

```
[ OK ] app-1      http://127.0.0.1:3101/healthz   200 in 3ms
[FAIL] bad-dns    http://doesnotexist.invalid/    got 000, expected 200 (curl exit 6: could not resolve host) in 5ms
[FAIL] bad-port   http://127.0.0.1:59999/healthz  got 000, expected 200 (curl exit 7: could not connect) in 1ms
[BAD ] malformed line: this-line-is-malformed
 3 of 4 checks FAILED

real    0m0.550s
exit code = 1
```

No hang, no crash: **0.55 seconds** for the whole run, exit 1. curl's exit codes
are translated into English (6 resolve, 7 connect, 28 timeout) because
"expected 200 got 000" does not tell you whether DNS, the network or the app is
at fault. The malformed line is reported as `[BAD ]` and counted as a failure
rather than silently skipped.

### Task 9 requirement 7 — proving the lock

`slow.conf` points at three unrouted `10.255.255.x` addresses, so each check
sits for the full 3s connect timeout and the run takes ~9s — a wide enough
window to start a second copy by hand:

```
20:14:41  first copy starts (pid 221295, slow.conf)
20:14:43  second copy starts, cannot take the lock, logs and exits 0
20:14:44  blackhole-1 fails after 3003ms
20:14:47  blackhole-2 fails after 3009ms
20:14:50  blackhole-3 fails after 3005ms
20:14:51  first copy ends, exit 1
```

```
second copy exit code = 0
[INFO] another healthcheck.sh is still running (lock /var/lock/abdur-healthcheck.lock held) -- exiting quietly
```

Exit **0** and not an error: a second copy declining to run is normal
operation, not a fault. If it exited non-zero, cron would email an alert every
five minutes for something working exactly as designed.

### Bugs I only found by running it — and one wrong diagnosis

These were invisible on a read-through:

1. **`date +%s%N` is GNU-only, and it took the whole loop down with it.** On
   macOS `%N` is not expanded, so the expression became
   `(( 1788281524N - start ) / 1000000 )`, bash reported *value too great for
   base*, and the script checked **one** service out of four before reporting
   `all 1 checks passed`. The reason it stopped is worth stating precisely: a
   failing arithmetic expansion aborts the **entire enclosing compound
   command**, so the `while` loop was abandoned, not just that iteration. Fix:
   take the timing from curl's own `%{time_total}`, which is more accurate
   anyway since it measures the request rather than the shell around it.

2. **An unopenable lock file killed the whole run.** Found by break test 1b,
   not by reading. As `abdur_alice` the script could not open
   `/var/lock/abdur-healthcheck.lock`, so it exited 1 *before reaching the
   config check* and checked nothing at all. Under cron as any non-root user
   that would have meant permanently silent monitoring — the exact failure I
   had already guarded against for a missing `flock` binary, but not here. It
   now warns loudly and continues without a lock, which is the same policy
   applied consistently.

3. **A missing `flock` binary read as "lock held".** `if ! flock -n 200` is
   true when `flock` does not exist (exit 127), so on macOS the script exited
   0 without checking anything at all. A monitoring script that silently does
   nothing is worse than one that crashes, so its absence is now a loud
   warning.

4. **A wrong diagnosis I corrected by experiment.** I originally believed the
   single-check symptom in bug 1 was caused by `curl` inheriting the loop's
   stdin — the config file — and consuming the remaining lines. I had changed
   `< /dev/null` and the timing code in the same edit, and credited the wrong
   one.

   Testing it separately disproved it:

   ```
   printf 'a\nb\nc\n' | while read -r l; do echo "read: $l"; curl ... ; done
     read: a      read: b      read: c        <- curl reads all three
   printf 'a\nb\nc\n' | while read -r l; do echo "read: $l"; cat >/dev/null; done
     read: a                                  <- cat eats the rest
   ```

   **curl does not read stdin for a plain GET**, so `< /dev/null` fixed
   nothing. It stays in the script as cheap insurance, because `ssh`, `mysql`,
   `ffmpeg` and `cat` genuinely do drain stdin and will silently swallow the
   rest of a config file in exactly this loop shape — `ssh -n` exists for
   precisely this reason. But the honest description is "defensive habit", not
   "this fixed my bug".

   The lesson is the one that produced the wrong answer in the first place:
   **change one thing at a time**, or you cannot tell which change was the fix.

### Task 11 — cron

[`configs/crontab-entry.txt`](configs/crontab-entry.txt), appended to root's
crontab:

```
*/5 * * * * /usr/local/bin/abdur-healthcheck.sh /etc/abdur-healthcheck/checks.conf >/dev/null
```

`PATH` is set explicitly in the crontab because cron's environment is nearly
empty — the single most common reason a script that "works when I run it" does
nothing from cron. Here it matters concretely: the script lives in
`/usr/local/bin`, which is not on cron's default `PATH`.

**Shared-machine note.** root's crontab already contained another student's
entry:

```
*/5 * * * * /srv/app/scripts/healthcheck.sh /srv/app/scripts/checks.conf
```

so I appended rather than replaced:

```bash
crontab -l 2>/dev/null | cat - configs/crontab-entry.txt | crontab -
```

`crontab configs/crontab-entry.txt` would have silently deleted their job. My
`PATH=` and `SHELL=` assignments sit *below* their line, and cron applies
variable assignments only to the entries that follow them, so their job is
unaffected. On a shared box the cleaner answer is a dedicated
`/etc/cron.d/abdur-healthcheck` file, which does not touch anyone's personal
crontab at all — I used the personal crontab only because the brief asks for
`crontab -l` as the evidence.

**Two separate cron runs**, from `/var/log/abdur-healthcheck.log`:

```
2026-09-02T20:10:02 [INFO]  run start config=/etc/abdur-healthcheck/checks.conf pid=219248
2026-09-02T20:10:02 [INFO]  OK   name=app-1 ... code=200 ms=2
2026-09-02T20:10:02 [INFO]  OK   name=app-2 ... code=200 ms=3
2026-09-02T20:10:03 [ERROR] FAIL name=nginx ... curl_rc=7
2026-09-02T20:10:04 [ERROR] run end status=degraded checked=3 failures=1 exit=1

2026-09-02T20:15:01 [INFO]  run start config=/etc/abdur-healthcheck/checks.conf pid=221496
2026-09-02T20:15:01 [INFO]  OK   name=app-1 ... code=200 ms=2
2026-09-02T20:15:02 [INFO]  OK   name=app-2 ... code=200 ms=7
2026-09-02T20:15:02 [ERROR] FAIL name=nginx ... curl_rc=7
2026-09-02T20:15:02 [ERROR] run end status=degraded checked=3 failures=1 exit=1
```

Distinct PIDs and five minutes apart. How to tell a cron run from one of my
manual runs in the same log: cron fires at **:01 to :04 seconds** past the
minute, because it wakes once a minute and then does its work. A `20:05:18`
entry in the same log is one of my own hand-runs, not cron — filtering on the
minute alone is not enough.

The `nginx` check fails in every run because nginx is not installed yet (A5).
That is deliberate: it gives the "both a passing and a failing service" output
the brief asks for, in real recurring data rather than a staged one-off.

## A4 — systemd

Unit: [`configs/myapp.service`](configs/myapp.service)

### Task 12 — The unit file

[`configs/myapp.service`](configs/myapp.service), installed as
`/etc/systemd/system/abdur-myapp.service`. The unit running, crashing and being
held down is captured across
[`evidence/a4-task13-always.txt`](evidence/a4-task13-always.txt),
[`evidence/a4-task13-limited.txt`](evidence/a4-task13-limited.txt),
[`evidence/a4-task14-journalctl.txt`](evidence/a4-task14-journalctl.txt) and
[`evidence/a4-task15-watchdog.txt`](evidence/a4-task15-watchdog.txt).

| Requirement | Directive | Why this one |
| --- | --- | --- |
| Run as a non-root, dedicated account | `User=abdur_myappuser`, `Group=abdur_myappuser` | A system account with `--shell /usr/sbin/nologin` and no home. Nothing else on the box runs as it, so a compromise of the app is scoped to the app |
| Start after the network is genuinely up | `Wants=network-online.target` + `After=network-online.target` | See below — the usual version of this is wrong |
| Order after the database | `After=postgresql.service` | Ordering **only**. Deliberately not `Requires=` |
| Restart on failure | `Restart=on-failure`, `RestartSec=1` | `on-failure`, not `always` — see task 13 |
| Tagged logging | `SyslogIdentifier=abdur-myapp` | Makes `journalctl -t abdur-myapp` work as well as `-u` |
| Start at boot | `WantedBy=multi-user.target` + `systemctl enable` | |
| Graceful stop | `KillSignal=SIGTERM`, `TimeoutStopSec=10` | In-flight requests finish before SIGKILL |

**`network.target` is not the one you want.** It means "the network stack has
been configured", which is true long before an address is routable.
`network-online.target` is the one that waits for a usable address — but it is a
passive target that does nothing unless something pulls it in, which is what
`Wants=` does. `After=network-online.target` **without** the `Wants=`, and
without `systemd-networkd-wait-online` / `NetworkManager-wait-online` enabled,
gives ordering that looks correct in the file and orders against nothing.

**`After=` versus `Requires=` for the database.** `After=` is ordering alone: if
postgres is dead, this unit still starts. `Requires=` would couple them, so a
failed database would stop the app from starting and a restarted database would
restart the app. I chose `After=`, because the app retries its connection and I
would rather it run and report itself unready — the `/readyz` versus `/healthz`
distinction from B2 task 26 — than refuse to start and lose the endpoint that
would tell me why.

**Hardening, which the brief did not ask for.** `NoNewPrivileges=true` alone
closes the entire setuid escalation path, and with `ProtectSystem=strict`,
`ProtectHome=true`, `PrivateTmp=true`, `RestrictSUIDSGID=true` and
`RestrictNamespaces=true` the difference is between "runs as a non-root user"
and "cannot become root". This has one real cost worth knowing:
`ProtectSystem=strict` makes the whole filesystem read-only, so the one path the
app legitimately writes has to be named — `ReadWritePaths=/srv/abdur/app/logs`.
Forgetting that line produces `EACCES` on a directory whose permissions look
perfectly correct in `ls -l`, which is a genuinely confusing way to fail.

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

**With `Restart=always` and `StartLimitBurst=0`** the same six crashes produce
the opposite outcome
([`evidence/a4-task13-always.txt`](evidence/a4-task13-always.txt)):

| | `StartLimitBurst=5` | `Restart=always`, `Burst=0` |
| --- | --- | --- |
| restart counter reaches | 5, then stops | 5, then keeps going |
| after crash 6 | `Start request repeated too quickly` | `Started abdur-myapp.service` |
| `systemctl is-active` | **failed** | **active (running)** |
| `Result` | `exit-code` | **`success`** |
| port 3100 | dead | `ok` — still answering |

The line that matters most is **`result: success`**. The app crashed six times
in twelve seconds and systemd reports success, because by its own definition it
succeeded: it was asked to keep a process running and it did. Any monitoring
that asks "has this unit failed?" gets **no**.

Note that *deleting* the StartLimit lines is not the same as disabling the
limit: systemd falls back to its defaults of 5 starts per 10s, so the service
would still give up and you would conclude the setting does not work. Hence
`StartLimitBurst=0` explicitly.

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

Transcript: [`evidence/a4-task14-journalctl.txt`](evidence/a4-task14-journalctl.txt).

**`-p` is a maximum, not an exact level.** `-p err` returns err *and everything
more severe* (crit, alert, emerg). Counting lines on my own journal proves it
rather than asserting it:

```
err and worse     :  1 lines
warning and worse : 17 lines
info and worse    : 97 lines
```

If it were an exact match those three numbers could not be nested like that.
`-p err..err` is the syntax for a single level.

**`-b -1` returned "No journal boot entry found from the specified boot offset
(-1)" — and the usual explanation is wrong here.** The common cause is a
volatile journal (`/run/log/journal` on tmpfs, wiped every boot), but on this
box:

```
$ journalctl --list-boots
IDX BOOT ID                          FIRST ENTRY                  LAST ENTRY
  0 b8babff209c94d9e8ba99e30dd18dc44 Thu 2026-08-27 16:00:30 CEST Wed 2026-09-02 20:32:23 CEST

$ ls -d /var/log/journal
/var/log/journal          <- persistent storage IS enabled
```

The journal is persistent; there is simply **only one boot recorded**, because
the VPS has been up since 27 August and has never rebooted. There is no
previous boot to show. `journalctl --list-boots` is what distinguishes the two
causes, and it is worth running before concluding the journal is misconfigured.

**`-f` caught the restart as it happened**, which is the point of the query:

```
20:32:28 systemd[1]: Stopping abdur-myapp.service...
20:32:28 abdur-myapp[227917]: SIGTERM received, shutting down
20:32:28 systemd[1]: abdur-myapp.service: Deactivated successfully.
20:32:28 systemd[1]: Started abdur-myapp.service
20:32:29 abdur-myapp[228253]: listening on 0.0.0.0:3100 (pid 228253)
```

`Deactivated successfully` rather than a kill is the graceful-shutdown handler
in the app doing its job.

**Bonus, and the reason `SyslogIdentifier` is in the unit:** `-u abdur-myapp`
returns systemd's messages *about* the unit as well as the app's own output,
while `-t abdur-myapp` returns only what the app itself wrote. When you want to
read application logs without systemd's lifecycle chatter, `-t` is the one.

### Task 15 — Alive but dead

Watchdog: [`configs/myapp-watchdog.sh`](configs/myapp-watchdog.sh) +
[`.service`](configs/myapp-watchdog.service) + [`.timer`](configs/myapp-watchdog.timer),
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

**Proof that systemd cannot see it**
([`evidence/a4-task15-watchdog.txt`](evidence/a4-task15-watchdog.txt)). Taken a
second after hitting `/hang`:

```
--- what systemd thinks ---
state    : active
main pid : 228253   (unchanged)
Active: active (running) since Wed 2026-09-02 20:32:28 CEST; 3min 12s ago

--- what a real request sees ---
curl --max-time 5 /healthz : TIMED OUT after 5s (curl exit 28)

--- and the socket is still open ---
LISTEN 0 511 0.0.0.0:3100  users:(("node",pid=228253,fd=24))
```

`Send-Q 511` is the kernel's accept backlog: the kernel is completing handshakes
and queueing connections on the app's behalf while the app never calls
`accept()`. From outside, the port looks perfectly alive.

**The watchdog catching it, with timestamps:**

```
20:35:38  watchdog: healthy: /healthz responded within 5s     <- last good check
20:35:46  /hang hit
20:36:08  timer due (30s after the last activation)
20:36:14  watchdog: UNHEALTHY: /healthz did not answer within 5s -- restarting abdur-myapp
20:36:14  watchdog: restart of abdur-myapp returned 0
20:36:16  new pid 229837, healthz: ok
```

**Measured recovery: 30 seconds** from hang to a working process.

The worst case is worth stating precisely, because it is what you would put in
an SLO: **30s (the timer interval) + 5s (the curl timeout) = 35 seconds** before
a restart even begins. Tightening it means either a shorter interval — more
probe traffic and more risk of restarting on a transient blip — or a shorter
curl timeout, which risks calling a merely-slow app dead. That trade is the
whole design of a liveness probe, and it is the same trade Kubernetes exposes
as `periodSeconds` and `timeoutSeconds`.

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

Evidence: [`evidence/a5-task16-whoami.txt`](evidence/a5-task16-whoami.txt),
requested from my laptop:

```json
{
    "remoteAddress": "127.0.0.1",          <- what the app can see by itself
    "realIpHeader":  "103.126.60.85",      <- my actual home IP
    "forwardedFor":  "103.126.60.85",
    "headers": {
        "host": "169.58.246.108",          <- original Host, not the upstream
        "x-forwarded-proto": "http",
        "x-forwarded-port": "8110"
    }
}
```

Direct to the backend, with no proxy in the way, the same endpoint returns
`"realIpHeader": null` — the headers exist only because nginx adds them.

A detail worth recording: `curl https://api.ipify.org` from the same machine
reported **103.126.60.87**, one octet away from the 103.126.60.85 nginx saw.
Both are in the same /24 — my ISP NATs customers behind a pool of public
addresses and different connections leave via different ones. That is the same
fact that makes `ip_hash` degenerate (task 17) and makes per-IP rate limiting
approximate (task 20): an "IP" is frequently not one user, and sometimes not
even one connection from one user.

### Task 17 — Load balancing algorithms

100 requests, `curl -s http://localhost/ | sort | uniq -c`:

| Algorithm | 3101 | 3102 | What it does |
| --- | --- | --- | --- |
| round robin (default) | **50** | **50** | strict alternation, blind to load |
| `least_conn` | **52** | **48** | picks the backend with fewest active connections |
| `ip_hash` (1st run) | 97 | 3 | hashes the client IP; one client = one backend |
| `ip_hash` (repeat) | **100** | **0** | see the note below |

**Why `ip_hash` needed running twice.** The first run gave 97/3, which should
be impossible for a deterministic hash from a single client IP. The cause was
the reload: `systemctl reload nginx` does not kill the old workers, it lets
them finish their existing connections while new workers start. The loop began
immediately after the reload, so the first few requests were served by old
workers still running the previous `least_conn` configuration. Re-running once
the workers had cycled gave exactly **100/0**. Worth knowing generally: a
measurement taken in the seconds after a reload can be measuring the old
config.

**A prerequisite finding: round-robin state is per worker process.** My first
three-request test sent all three to 3101 and looked broken. nginx runs
`worker_processes auto` — four workers on this box — and each keeps its own
round-robin cursor, so each worker's *first* request goes to the first upstream.
Small samples therefore look badly skewed while 100 requests come out 50/50.
This is the same per-worker state that explains the failover numbers in task 18.

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

Measured with [`configs/a5-task18.sh`](configs/a5-task18.sh) —
[run 1](evidence/a5-task18-run1.txt), [run 2](evidence/a5-task18-run2.txt).

**Two different numbers have to be measured, not one.** The config sets
`proxy_next_upstream error timeout http_502 http_503 http_504`, so when a
backend fails nginx silently retries the request on the healthy one. Counting
only what the client saw would give "0 failures" and the conclusion that
nothing broke. The failures are real; they are in nginx's error log.

| | `max_fails=3 fail_timeout=10s` | `max_fails=1 fail_timeout=30s` |
| --- | --- | --- |
| Downtime in the test | 35 s | 15 s |
| **Client-visible failures** | **0** | **0** |
| **Upstream failures in nginx's log** | **16 lines** | **6 lines** |
| Time from stop to ejection | ~3.0 s | **~0.4 s** |
| Time from restart to traffic returning | **0.93 s** | **5.6 s** |

**Why 16 and not 3.** `max_fails` is counted **per worker process**, not
globally — an upstream without a `zone` directive keeps its peer state in each
worker's own memory. The log confirms it exactly:

```
$ grep '20:58:' error.log | grep -oP '#\K[0-9]+' | sort | uniq -c
      4 237233
      4 237234
      4 237235
      4 237236
$ grep -c 'temporarily disabled' error.log
4
```

Four workers × (3 `connect() failed` + 1 `temporarily disabled`) = 16. The
practical consequence: with `max_fails=3` and four workers, **up to twelve real
requests can hit a dead backend** before every worker has ejected it. That
number scales with `worker_processes`, which is not obvious from the directive.

**Why `fail_timeout` governs both halves.** It is simultaneously the window in
which failures are counted *and* the length of the ban. So a backend ejected
with `fail_timeout=10s` is retried 10 seconds later; the retry is a real user's
request, because nginx open source never probes on its own. That is why a
single isolated failure reappears periodically while a backend stays down —
each one is a probe someone paid for.

**A prediction that was wrong, and what it taught me.** I expected run 2 to
recover in ~15 s, because the backend returned while still inside its 30 s ban.
It recovered in **5.6 s**. The reason is again per-worker state: only three of
the four workers ever sent a request to 3102 while it was down, so the fourth
never marked it as failed and never banned it. When 3102 came back, that worker
routed to it immediately without waiting for anyone's ban to expire.

```
workers running   : 241623  241625  241626  241627
workers in the log: 241623  241625  241626           <- 241627 never saw a failure
```

So "the backend is ejected" is not a property of nginx; it is a property of
*each worker*, and recovery is as fast as the most optimistic worker. Adding
`zone upstream_name 64k;` to the upstream block puts that state in shared
memory and makes the behaviour uniform — which is exactly why that directive
exists.

**The trade between the two settings.** `max_fails=1` ejects roughly 7× faster
and wastes far fewer requests, but bans for 30 s, so one transient blip removes
a healthy backend for half a minute. Under mild packet loss it can eject
backends one after another; nginx's safety valve is that when *every* upstream
is marked down it clears the flags and tries them all again rather than
returning 502 to everyone.

**The honest limitation.** All of this is passive. nginx open source has no
active probing (`health_check` is nginx Plus), so a backend is never known-good
until a real user pays to find out. Alternatives: HAProxy in front,
`ngx_http_upstream_check_module`, or a service mesh.

### Task 19 — The 504, and why raising the timeout is the wrong fix

Measured in [`evidence/a5-task19-20.txt`](evidence/a5-task19-20.txt):

```
proxy_read_timeout  5s  ->  http_code=504  time=5.009152s
proxy_read_timeout 60s  ->  http_code=200  time=45.015691s
```

and the error nginx logged for the 504:

```
[error] upstream timed out (110: Connection timed out) while reading response
        header from upstream, upstream: "http://127.0.0.1:3101/slow"
```

**Something I did not expect, and it strengthens the argument below.** The same
504 also produced:

```
[warn] upstream server temporarily disabled while reading response header from
       upstream, upstream: "http://127.0.0.1:3101/slow"
```

The timeout counted as a failure against `max_fails`, so **one slow request
ejected a completely healthy backend from the rotation**. `proxy_next_upstream
off` on that location prevents the request being retried elsewhere; it does not
stop the failure being counted. With `max_fails=1` a single slow request costs
you half your capacity for `fail_timeout` seconds.

**Why raising it is usually wrong.** The timeout is not the problem; it is the
alarm. And on this system it is not even only about worker connections: as
measured above, a request that exceeds the timeout is counted as an upstream
failure, so a slow endpoint can eject healthy backends and *reduce* the
capacity available to everything else. Raising the timeout hides that, at the
cost of holding the resources for longer. Raising it silences the alarm and leaves the 45-second request in place,
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

50 requests as fast as possible:

```
     29 404
     21 429
```

(404 rather than 200 because `/api/notes` belongs to the Scenario B app and
does not exist here. That makes the test *stronger*, not weaker: a 429 is
produced by nginx before the request is proxied at all, so a 404/429 mix proves
the rejection is nginx's and not the backend's.)

**Why 29 got through.** `burst=20` allows 20 immediately, and the 50 requests
took about a second, during which `rate=10r/s` refilled roughly 9 more. 20 + 9
= 29. The arithmetic matching is what tells you the limiter is configured the
way you think it is.

**A control test I added.** Firing 50 requests fast and seeing 429s does not by
itself prove rate limiting — a naive "reject everything after the 21st request"
would look identical. So I repeated it with a 0.2 s gap, which is inside the
10r/s budget:

```
     20 404          <- zero 429s
```

Same endpoint, same count, no rejections. The limiter is measuring *rate*.

nginx's own log shows the running excess counter:

```
[warn] limiting requests, excess: 20.720 by zone "abdur_api_limit", client: 127.0.0.1
```

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
