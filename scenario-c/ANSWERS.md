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

**User:** `abdur-exam-deployer` — not `exam-deployer`, which already belonged to
another student in this shared account (see *Constraints* above).
**Policy:** [`iam/abdur-exam-deployer-policy.json`](iam/abdur-exam-deployer-policy.json),
`arn:aws:iam::750069566598:policy/abdur-exam-deployer-policy`.

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "EcrLoginTokenIsRegistryWideAndCannotBeScopedSoResourceIsStar",
      "Effect": "Allow",
      "Action": "ecr:GetAuthorizationToken",
      "Resource": "*"
    },
    {
      "Sid": "PushToTheAbdurNotesApiRepositoryOnly",
      "Effect": "Allow",
      "Action": [
        "ecr:BatchCheckLayerAvailability",
        "ecr:InitiateLayerUpload",
        "ecr:UploadLayerPart",
        "ecr:CompleteLayerUpload",
        "ecr:PutImage"
      ],
      "Resource": "arn:aws:ecr:eu-north-1:750069566598:repository/abdur-notes-api"
    },
    {
      "Sid": "UpdateTheAbdurNotesSvcServiceOnly",
      "Effect": "Allow",
      "Action": "ecs:UpdateService",
      "Resource": "arn:aws:ecs:eu-north-1:750069566598:service/abdur-exam-cluster/abdur-notes-svc"
    }
  ]
}
```

#### The one `"*"`, and where its comment is

IAM policy documents are strict JSON, which has **no comment syntax**. The brief
asks for a comment beside every unavoidable `"*"`, so the **`Sid` carries it**:
`EcrLoginTokenIsRegistryWideAndCannotBeScopedSoResourceIsStar`. The reason is
visible to anyone reading the policy in the console, not only in this file.

The reason itself: `ecr:GetAuthorizationToken` returns a login token for the
**whole registry**, not for a repository, and AWS does not support resource-level
permissions on it — an ARN in that `Resource` makes the statement never match.
It is also harmless on its own. A token only authenticates; every action that
does anything with it is in the second statement, which is pinned to one
repository ARN.

#### What I removed from my own first draft

The first version also granted `ecr:BatchGetImage` and `ecs:DescribeServices`.
Both came out on re-reading, because "nothing else" is the requirement:

- `ecr:BatchGetImage` is the **pull** action. `docker push` never calls it — it
  checks layer existence (`BatchCheckLayerAvailability`), uploads, and writes the
  manifest (`PutImage`). A deployer that can pull can also exfiltrate every image
  in the repository.
- `ecs:DescribeServices` is not needed to update a service —
  `aws ecs update-service` returns the updated service description in its own
  response.

If either turned out to be necessary, the denial message would name the exact
missing action, which is the right way to find out.

#### Attached, and nothing else attached

```
Permissions policies (1)
  abdur-exam-deployer-policy    Customer managed    Attached directly
Permissions boundary            (not set)
Groups                          0
Console password                none
Access keys                     none until the push test, deleted after it
```

`Groups: 0` matters more than it looks. IAM permissions are a **union**: a policy
never narrows what another grants. In an account where `AdministratorAccess` is
attached to seven identities, putting this user in the wrong group would silently
make every line of the policy above irrelevant.

No console password, because a deployer is a machine identity. A password it
never uses is still a credential that can leak.

The console's summary of the policy reads **"Allow (2 of 475 services)"** —
Elastic Container Registry and Elastic Container Service.

#### "Limited: Read, Write" — why Read, if pull was removed?

The policy summary labels ECR as **Read, Write**, which looks like it contradicts
removing the pull action. It does not. IAM files every action under an access
level, and AWS itself classifies two of the push prerequisites as *Read*:

| Action | AWS access level | What it actually does |
| --- | --- | --- |
| `ecr:GetAuthorizationToken` | Read | fetch a login token |
| `ecr:BatchCheckLayerAvailability` | Read | ask "does this layer already exist?" before uploading it |
| `ecr:BatchGetImage` | Read | **download an image — not granted** |

So the label describes the *category* of the granted actions, not a capability.
It is tested directly rather than argued: the push run below calls
`ecr batch-get-image` as this user and records the denial.

Evidence: `evidence/c1-task47-user-permissions.png`,
`evidence/c1-task47-policy-summary.png`.

<!-- status: policy + user done; push and denial tests pending -->

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

**Repository:** `750069566598.dkr.ecr.eu-north-1.amazonaws.com/abdur-notes-api`

| Setting | Chosen | Why |
| --- | --- | --- |
| Visibility | Private | a public repo lets anyone pull the image |
| Tag mutability | **Mutable, with `v1.0.*` and `sha-*` excluded** | see below |
| Encryption | AES-256 | encryption at rest either way; KMS adds $1/key/month plus API charges to an account already over budget |
| Scan on push | On | basic scanning is free and checks OS packages for known CVEs on every push |
| Tag | `exam-token` | puts the token on every console screenshot of the resource itself |

**The mutability choice is the only real decision on that page.** Immutable tags
are what you want for release versions — `v1.0.66` should name one image
forever, and B4 task 38's rollback only works because the previous version is a
specific artefact nobody can overwrite. But the CI also pushes `latest`, whose
entire job is to move, and a fully immutable repository rejects the second push
of it.

ECR's *mutable tag exclusions* resolve that directly: the repository is mutable,
and tags matching `v1.0.*` or `sha-*` are immutable. So version and commit tags
are fixed artefacts while `latest` is free to move — and `latest` is never a
deploy target anywhere in this repository.

**The cost of that choice, stated in advance:** re-running CI on the *same*
commit will now fail at the push step with `tag invalid: already exists`. A
rebuild of the same source is not byte-identical (layer timestamps change), so
it is a genuinely different image claiming an existing version number, and
refusing it is the setting doing its job. The task 53 pipeline therefore checks
whether the tag already exists before pushing. B5 needed five re-runs of one
deploy; with this setting each would have stopped at the registry.

One console note: repository-level *scan on push* is marked **deprecated** in
favour of registry-level scanning filters (*Features & Settings → Scanning*). It
still works; the registry-level filter is the current way to configure it.

<!-- status: repository created; image not yet pushed -->

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
