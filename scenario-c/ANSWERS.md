# Scenario C — AWS and Multi-Tenancy (94 marks)

**Exam token:** `root-vmi3536696-1788282556-1536d427`
**Account:** `Arraytics_aws` / **750069566598**, IAM user `rasel`
**Region for all regional resources:** `eu-north-1` (Stockholm)

> Covers sessions 6–9. Every number and screenshot below is from this account.

---

## Constraints that shape every answer in this scenario

These were established before creating anything, by opening each service console
and recording what did and did not load (`evidence/c0-permissions.md`). Three of
them change what the tasks can mean.

### 1. The account is shared with other students

It held **9 IAM users** when I started — `alamin`, `ashik`, `badhon`,
`exam-deployer`, `faruq`, `fc-exam-deployer`, `nafila`, `rasel`, `zaman`.

**Task 47 asks for a user called `exam-deployer`, and that name was already
taken** by another student before I began; `fc-exam-deployer` shows someone else
hit the same wall and prefixed their way out. So every resource I create is
prefixed **`abdur-`**, and I touch nothing I did not create:

| Brief says | I created | Why |
| --- | --- | --- |
| `exam-deployer` | `abdur-exam-deployer` | the plain name was already another student's |
| ECR repository | `abdur-notes-api` | shared registry |
| ECS cluster | `abdur-exam-cluster` | shared account |
| S3 bucket | `abdur-notes-750069566598` | bucket names are globally unique across all of AWS |

Editing the existing `exam-deployer`'s policy to satisfy task 47 would have
broken another student's submission, and left mine open to the same.

### 2. No root access

The account was handed to me as an IAM user. Anything needing root — enabling
*IAM access to Billing Information*, for instance — cannot be done, and where a
task depends on it that is stated rather than skipped.

### 3. Cost figures are denied, and the account is already over budget

The Billing console opens, but every cost figure reads **Access denied**:
month-to-date, forecast, and last month. What *is* visible is the Budgets
widget, and it already says **"1 over budget"** — before I had created anything.

This changes task 63 from a formality into the thing to be most careful about.
It also means the brief's "set a billing alarm at $5 before you start" is not
available to me: `budgets:ModifyBudget` is not granted, and the existing budget
belongs to whoever owns the account.

**Neither ALB nor Fargate is free tier** on an account this old — roughly
**$0.54/day** for the load balancer and **$0.55/day** for two 256/512 Fargate
tasks, so about **$1/day** while C2 is standing up. Everything is deleted in
task 63 and the listing proves it.

---

## C1 — IAM basics (8 marks)

### Task 47 (4 marks) — A user with limited permissions

Requirements: an IAM user or role that can push to ECR and update an ECS
service, **and nothing else**. A custom policy whose `Resource` names the
specific repository and service, not `"*"`. Every unavoidable `"*"` needs a
comment saying why.

Deliverables: the policy JSON, a screenshot of the user pushing to ECR, and a
screenshot of the same user being denied something else (e.g. `aws s3 ls` →
AccessDenied).

<!-- status: not started -->

### Task 48 (4 marks) — Test your policies

Four actions through the IAM Policy Simulator (console or
`aws iam simulate-principal-policy`): two that must be allowed, two that must be
denied. Screenshots of the results.

<!-- status: not started -->

---

## C2 — Get the app running on AWS (36 marks)

Goal: the Notes API on ECS Fargate, reachable over the internet, deployed by the
CI/CD pipeline from Scenario B. Default VPC; keep the networking simple.

### Task 49 (4 marks) — Push the image to ECR

Deliverable: screenshot of the image in ECR with its tag and size.

<!-- status: not started -->

### Task 50 (8 marks) — Task definition

Fargate, 256 CPU / 512 memory, with: the ECR container, a port mapping for
3000, **CloudWatch logs via the `awslogs` driver**, a container health check,
and environment variables for the DB connection.

Deliverables: the task definition JSON committed here with the account ID
redacted, a screenshot of the running task, and a screenshot of the app's logs
in CloudWatch Logs.

<!-- status: not started -->

### Task 51 (8 marks) — Service behind a load balancer

Deliverable: repeated requests to the ALB showing responses from **different
tasks** — a different container IP or hostname in each response, visible in the
screenshot.

<!-- status: not started -->

### Task 52 (6 marks) — Autoscaling

One target-tracking policy: `ECSServiceAverageCPUUtilization` at 50%, min 2,
max 6. Then actually trigger it, e.g.
`hey -z 5m -c 50 "http://<alb-dns>/api/search?q=abc"` — the unindexed search
endpoint burns CPU.

Deliverables: the policy configuration, a CloudWatch CPU graph showing the
spike, the service's *Deployments and events* tab with timestamps, a screenshot
of the task count rising above 2, and then scale-in after the load stops, with
the scale-in duration noted.

**Question for ANSWERS.md:** how long between CPU going high and a new task
actually serving traffic? Add up the CloudWatch metric delay, the alarm
evaluation period, task startup and health checks passing. Why does that mean
autoscaling cannot save you from a sudden spike?

<!-- status: not started -->

### Task 53 (8 marks) — Deploy from CI/CD

Extend the GitHub Actions pipeline: on push to main, build, push to ECR, update
the ECS service.

Deliverables: a successful pipeline run deploying to ECS, the ECS service
showing the new task definition revision, and the trust policy showing the repo
condition.

<!-- status: not started -->

### Task 54 (2 marks) — Something is broken, debug it

Break one thing deliberately (wrong target-group port, or a health check path
that 404s), then debug it and write down **the exact order of checks used**.
Deliverables: that list, plus screenshots of the failure and the fixed state.

<!-- status: not started -->

---

## C3 — S3 and file uploads (20 marks)

### Task 55 (5 marks) — A private bucket and a presigned upload

A bucket with **all public access blocked** (the default — leave it on), an
endpoint `POST /api/attachments/upload-url` returning a presigned PUT URL, and
an upload through it with `curl -X PUT --upload-file`.

Deliverables: the generated URL, the successful upload, the object in the S3
console.

<!-- status: not started -->

### Task 56 (4 marks) — Presigned download and expiry

`GET /api/attachments/:key/download-url` returning a presigned GET URL with a
**60 second** expiry. Open it (works), wait 61 seconds, open it again and
screenshot **the exact XML error** S3 returns. Also show a plain unsigned
request to the object → AccessDenied.

**Question for ANSWERS.md:** if a user posts their presigned URL in a public
Telegram group, what can strangers do and for how long? Give **two different**
ways to reduce the risk, and say which one you would actually implement and why.

<!-- status: not started -->

### Task 57 (6 marks) — Two access patterns in one bucket

- `tenants/<tenant>/private/*` — presigned only, never public
- `public/*` — anyone can read with a plain URL, no signing

Prove all three, one screenshot each: plain URL to `public/` works; plain URL to
`tenants/acme/private/` is AccessDenied; presigned URL to that same private file
works.

<!-- status: not started -->

### Task 58 (5 marks) — Tenant isolation

`acme` must never read `globex`'s files even knowing the key. The check happens
**in application code, before anything is signed**. Prove it: as `acme`, request
a presigned URL for a `globex` key, and screenshot the 403.

<!-- status: not started -->

---

## C4 — Multi-tenancy with subdomains (26 marks)

No TLS required; HTTP is fine. One application instance serves every tenant,
routing on the `Host` header. A customer can also bring their own domain.

A real domain is needed. A cheap `.xyz`, DuckDNS or nip.io all count.
`/etc/hosts` simulation is allowed but **loses 3 marks** and must be declared.

### Task 59 (8 marks) — Wildcard DNS and Host-based routing

Prove: `acme.<domain>/api/notes` returns acme's notes; `globex.<domain>` returns
different notes; `doesnotexist.<domain>` returns a clean 404 rather than a
crash; and `docker ps` / `systemctl status` shows only **one** app instance
serving all of them.

<!-- status: not started -->

### Task 60 (7 marks) — Automatic tenant provisioning

`POST /api/tenants` taking `{"slug","name"}` which inserts the row, does the
per-tenant setup (S3 prefix, seed data), and returns the tenant's URL. Because
of wildcard DNS and a regex server block, **no DNS or nginx change is needed** —
prove it in one terminal session: provision, then immediately curl the new
subdomain.

**Questions for ANSWERS.md:** why was no nginx or DNS change needed? What
validation does `slug` need — what about `www`, `api`, `admin`, or a slug with a
dot in it? Implement at least a reserved-name blocklist and show it rejecting
one.

<!-- status: not started -->

### Task 61 (6 marks) — Custom domain

`notes.theircompany.com` instead of `theircompany.<domain>`. A real second
domain scores full marks; state clearly which route was taken.

<!-- status: not started -->

### Task 62 (5 marks) — What can go wrong

Answer in ANSWERS.md; a demonstration doubles the marks for each point.

1. A customer points DNS at you before verifying — what does a visitor see?
   Fix it so unknown domains get a "domain not configured" page rather than an
   error or, worse, another tenant's data.
2. Two tenants both claim `notes.example.com` — what stops the second? Show the
   constraint or check, and the error the second tenant gets.
3. **The tenant header can be faked.** What stops
   `curl -H "X-Tenant: globex" http://acme.<domain>/api/notes`? Test it. If it
   works, that is a real vulnerability — fix it (nginx must always overwrite the
   header, never pass a client-supplied one) and show it fixed.
4. Find **one more** isolation bug in your own code — a query missing its
   `WHERE tenant_id`, a cache key without the tenant, an id lookup that does not
   check ownership, or a log line leaking across tenants.

<!-- status: not started -->

---

## C5 — Clean up (4 marks)

### Task 63 (4 marks) — Delete everything

ECS service and cluster, ALB, target groups, ECR images, S3 bucket contents and
the bucket, RDS, secrets, IAM roles no longer needed, EC2 instances.

Deliverables: the output of

```bash
aws ecs list-clusters
aws elbv2 describe-load-balancers
aws s3 ls
aws ec2 describe-instances \
  --query 'Reservations[].Instances[?State.Name!=`terminated`].InstanceId'
```

showing nothing left, plus a screenshot of the Billing or Cost Explorer page.

**Known limit:** the cost figures on that page are `Access denied` for this IAM
user (see constraints above), so the billing screenshot will show the denial
rather than a number. The resource listings are unaffected and are the part that
proves nothing is still running.

<!-- status: not started -->
