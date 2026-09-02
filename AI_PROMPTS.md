# AI_PROMPTS.md

Log of where AI actually helped, where it was wrong, and what I had to change to
make the answer work on my machine.

> Marker's bar: pasting prompts without saying what went wrong = 2 marks.
> Full marks need at least 8 entries that show the gap between the generic
> answer and the real problem.

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
- **What actually fixed it:** <fill in what you had to change once you ran it>

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

<!--
Entries 3-8+: write these as you hit real problems. Good candidates from this exam,
if they happen to you:
  - dan can ls but not cat (ACL vs directory x bit)
  - carol cannot rm her own files (sticky bit)
  - sudoers NOPASSWD scoped to one systemctl unit, and why a wildcard is dangerous
  - "ss -lptn shows no PID without sudo"
  - systemd StartLimitBurst in [Unit] vs [Service] on your systemd version
  - nginx upstream 'localhost' resolving to ::1
  - depends_on not waiting for Postgres to be ready
  - container exit 137 vs 143
  - Prometheus high-cardinality route labels
  - Swarm rolling update non-200s
-->
