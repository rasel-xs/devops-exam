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

<!--
Entries 2-8+: write these as you hit real problems. Good candidates from this exam,
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
