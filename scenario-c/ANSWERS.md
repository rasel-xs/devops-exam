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

### 3. The account was already over budget — and billing visibility changed mid-scenario

**On 2026-09-12**, the Billing console opened but every cost figure read
**Access denied** — month-to-date, forecast, last month. Only the Budgets widget
was visible, and it already said **"1 over budget"** before I had created
anything. This user has what looks like `AdministratorAccess` (attached to seven
identities), so the denial was not an IAM policy: billing data is gated
separately, by the root user enabling *IAM user and role access to Billing
information*.

**By 2026-09-14** that had been switched on, and the same page showed real
figures (`evidence/c0-billing-mtd.png`):

```
Month-to-date cost (Sep 1-14)   $10.61
Last month, same period         $0.00
Last month total                $0.00
Forecast                        Data unavailable
Budgets                         1 over budget
```

**None of the $10.61 is mine.** At that point I had created an empty ECR
repository, an ECS cluster with no tasks, and an IAM user and policy — all of
which cost nothing while idle. The baseline (`evidence/c0-account-baseline.md`, from
`evidence/c0-global-view.png` and `evidence/c0-tag-editor.png`) records what
*was* billable: one running ECS service and two Elastic IPs belonging to other
students. $10.61 over
14 days is about $0.76 a day, inside the $0.50–1.00 range the baseline estimated
from those resources before the figure was visible. Cost Explorer's default six-month view, grouped by
service (`evidence/c0-cost-explorer-6-months.png`), shows **$0.00 across
March–August** with a service count of 0, so every dollar of the overspend is
September's. I had intended to capture a *daily* September view showing the
spend accruing before my first resource existed (the policy, 2026-09-13 00:49
+06:00), but the screenshot taken is the default range, not the daily one, so
that specific claim rests on the baseline rather than on a Cost Explorer graph.

"Forecast: Data unavailable" is expected rather than a permission problem — Cost
Explorer needs enough usage history to project from, and last month was $0.

The brief's "set a billing alarm at $5 before you start" was not something I
could meaningfully do: the account's only budget already existed, belonged to
whoever administers it, and was already exceeded by spend that predates me.

**Neither ALB nor Fargate is free tier** on an account this old — roughly
**$0.54/day** for the load balancer and **$0.55/day** for two 256/512 Fargate
tasks, so about **$1/day** while C2 is standing up. Everything is deleted in
task 63 and the listing proves it.

### 4. CloudShell was unavailable, so C2 onwards runs from the AWS CLI on my laptop

Tasks 47–50 were done in the console. For task 51 I moved to scripts, so every
step is repeatable and its output is evidence rather than a screenshot of a
form. **AWS CloudShell refused to start** in this account: *"Unable to create
the environment. Your account verification is in progress"* — an account-level
state only the account owner can resolve, not an IAM permission. Deleting the
environment and retrying gave the same result.

So AWS CLI v2.36.44 was installed on my laptop (into my home directory, no
`sudo`; removed in task 63), and authenticated with **`aws login`**: it signs in
through the browser with the same console user and gives the CLI short-lived
credentials. **No access key was created for `rasel`.** The obvious alternative
— an access key on the exam VPS, where AWS CLI is already installed — was
rejected: every student there is root, and `rasel` is close to an
administrator in a shared account. Every script checks that the caller is
`arn:aws:iam::750069566598:user/rasel` before doing anything.

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
**Policy:** [`iam/abdur-exam-deployer-policy.json`](iam/abdur-exam-deployer-policy.json)
(`evidence/c1-task47-policy-json-editor.png` shows version 1 as first pasted,
before `ecr:BatchGetImage` was added back — see below),
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
        "ecr:PutImage",
        "ecr:BatchGetImage"
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

#### What I removed from my first draft — and had to put one back

The first version granted `ecr:BatchGetImage` and `ecs:DescribeServices`. Both
came out on re-reading, because "nothing else" is the requirement:

- `ecs:DescribeServices` is not needed to update a service —
  `aws ecs update-service` returns the updated service description in its own
  response. **This one stayed out.**
- `ecr:BatchGetImage` is the pull action, and I wrote that `docker push` never
  calls it. **That was wrong, and the push proved it.**

I had also written that if either removal turned out to matter, the denial
message would name the exact missing action. That is what happened. Run 2
(`evidence/c1-task47-push-run2-batchgetimage.txt`) authenticated as the right
identity, uploaded **every layer**, and was then refused at the last step:

```
identity confirmed: arn:aws:iam::750069566598:user/abdur-exam-deployer
Login Succeeded
fff4e2c1b189: Pushed   b2cbbfe903b0: Pushed   3af0bc5a14b9: Pushed
6eb6b44777c2: Pushed   d33c4d5a9e94: Pushed   9760138fb43e: Pushed
da8c5328bfeb: Pushed   6a0ac1617861: Pushed   d9ca22a5a2c3: Pushed
4feea04c1543: Pushed
error from registry: User: arn:aws:iam::750069566598:user/abdur-exam-deployer
  is not authorized to perform: ecr:BatchGetImage on resource:
  arn:aws:ecr:eu-north-1:750069566598:repository/abdur-notes-api
  because no identity-based policy allows the ecr:BatchGetImage action
```

The failure came **after the layers and before the tag existed** — at the
manifest. Before writing a manifest, the client asks the registry whether that
manifest is already there, and ECR authorises that lookup as
`ecr:BatchGetImage`. AWS's own sample push policy includes it for this reason; I
had reasoned from the upload protocol and not checked.

It is back in, on the same single-repository ARN. Granting it does let this
identity pull from `abdur-notes-api`, and the honest risk assessment is that
this adds very little: an identity that can push arbitrary content into a
repository already controls what that repository contains, so reading back
what it can write is not a meaningful new capability. It still cannot touch any
other repository — which the scope test below demonstrates rather than asserts.

This is also the method working as intended rather than a failure of it. Start
narrower than you think is needed, and let an explicit denial — which names the
action, the resource and the reason — tell you what to add. The alternative, a
broad grant trimmed later, never gets trimmed.

**A side effect worth recording:** ten layers now sit in the repository with no
manifest referencing them. They are invisible in the console (there is no tag)
and are simply reused as "Layer already exists" by the next push, so the re-run
only had to write the manifest.

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

#### "Limited: Read, Write" — what the label does and does not mean

The console summarises ECR as **Read, Write**. IAM files every action under an
access level, and AWS classifies three of the granted actions as *Read*:

| Action | AWS access level | What it actually does |
| --- | --- | --- |
| `ecr:GetAuthorizationToken` | Read | fetch a login token |
| `ecr:BatchCheckLayerAvailability` | Read | ask "does this layer already exist?" before uploading it |
| `ecr:BatchGetImage` | Read | fetch an image manifest — needed by push itself (see above) |

When the policy screenshot was taken, only the first two were granted and I
wrote that "Read" therefore did not mean the user could pull. After run 2 that
is no longer true: this identity **can** pull from `abdur-notes-api`, and the
label is now literally accurate. The claim that matters for task 47 is a
different one — that every non-login action is pinned to **one** repository —
and that is tested directly: the push run calls a *granted* ECR action against a
repository the policy does not name, and records the denial.

Evidence: `evidence/c1-task47-user-permissions.png`,
`evidence/c1-task47-policy-summary.png`.

#### The push, and six denials — run 3

[`c1-task47-push.sh`](c1-task47-push.sh), transcript
`evidence/c1-task47-push.txt`. The transcript is the evidence for this run: the
script stamps `EXAM_TOKEN | date` before each section, so every block below
carries the token inline. No terminal screenshots of run 3 were kept.

```
identity confirmed: arn:aws:iam::750069566598:user/abdur-exam-deployer
Login Succeeded
fff4e2c1b189: Layer already exists        (all ten, left behind by run 2)
v1.0.69: digest: sha256:e11a0591643dc874a5f5e0464504afb584b32fc17f420d76687256d6bf059bdf size: 2187
push exit code: 0
```

| # | Call, as `abdur-exam-deployer` | Result |
| --- | --- | --- |
| 1 | `aws s3 ls` | `AccessDenied` — `s3:ListAllMyBuckets` |
| 2 | `aws ecs list-clusters` | `AccessDeniedException` — `ecs:ListClusters on resource: *` |
| 3 | `aws ecr describe-repositories` | `AccessDeniedException` — `ecr:DescribeRepositories on …repository/*` |
| 4 | **granted** `ecr:BatchCheckLayerAvailability`, on `abdur-not-this-repo` | `AccessDeniedException` |
| 5 | **granted** `ecs:UpdateService`, on `abdur-exam-cluster/abdur-not-this-svc` | `AccessDeniedException` |
| 6 | `aws iam list-attached-user-policies` | `AccessDenied` |

Every one of the six was checked by the script to be an authorization denial
rather than some other failure (see *run 1* below for why that check exists):
`=== all 6 outside-policy calls were genuinely denied ===`.

**Rows 4 and 5 are the ones that carry task 47.** Rows 1–3 and 6 show actions the
policy never mentions being refused, which any narrow policy would do. Rows 4
and 5 use actions the policy **does** grant — row 4's action had succeeded five
seconds earlier, as the "Layer already exists" lines of this very push — against
a repository and a service the policy does not name. That is the `Resource`
field doing its job, observed rather than asserted. Both targets deliberately do
not exist, so even a policy that was wrongly broad could not have changed
anything real.

Three details in those errors are worth reading closely:

- **`AccessDenied`, not `RepositoryNotFound`.** `abdur-not-this-repo` does not
  exist, and AWS still answered with a denial. Authorization is evaluated before
  existence, which also means an identity without permission cannot use error
  messages to discover which repositories do exist.
- **"because no identity-based policy allows the … action"** appears in every
  error. That is an *implicit* deny — nothing granted it. An SCP or an explicit
  `Deny` statement produces a differently worded message ("with an explicit
  deny in a service control policy"). So these refusals come from this policy's
  narrowness alone, not from some other control in the account.
- **The command, the API and the IAM action are three different names.**
  `aws s3 ls` calls the `ListBuckets` API, which IAM authorises as
  `s3:ListAllMyBuckets`. A policy has to be written in the last of those, and the
  denial message is the most reliable place to learn it.

#### The secret never touched the shared disk

The VPS is shared and every student on it is root, so the script took the key
at a prompt, held it only in its own environment, pointed
`AWS_SHARED_CREDENTIALS_FILE` at `/dev/null`, and sent `docker login`'s 12-hour
ECR token to a temporary `DOCKER_CONFIG` removed on exit. Docker's own warning
confirms where the token went — `/tmp/tmp.MTMQGz1IiS/config.json`, not
`/root/.docker/config.json` — and after run 2 the equivalent directory was
checked and gone:

```
$ ls /tmp/tmp.lHHDlST887
ls: cannot access '/tmp/tmp.lHHDlST887': No such file or directory
```

The access key was deactivated and deleted immediately after run 3
(`evidence/c1-task47-key-deleted.png`). I wrote at first that the key ID in the transcripts had been redacted. There
was nothing to redact: the committed transcripts contain no key ID at all. What
you type at a prompt is echoed to the screen by the terminal, not written by the
program, so it never enters the pipe that `tee` records — the ID was visible on
screen and absent from the file. (It identifies a deleted key and was never a
secret on its own.)

#### Run 1 produced false evidence, and that is why the script checks

Run 1's transcript was **not preserved**: before it could be renamed, further
accidental re-runs — old terminal output pasted back into the shell, which
executed the `bash … | tee` lines inside it — overwrote the same file. The lines
quoted here are from the terminal output captured during the session. It is
worth recording because of what it nearly got away with. A multi-line paste arrived while the script was
starting, and its own prompts consumed the still-buffered lines — the "access
key ID" was `cd /root/abdur-exam`. Every call then failed with
`IncompleteSignature` or `AuthorizationHeaderMalformed`: a space inside the key
ID breaks the `Credential=` field of the SigV4 header, so AWS rejected each
request **before identifying anyone**.

The script at that point did not stop when identity verification failed, and it
printed all five of those failures under a heading that read **DENIED**. Read
quickly, the transcript proved task 47. It proved nothing.

The script now drains typeahead before prompting and reads from `/dev/tty`,
format-checks the key ID and secret, refuses to run any test unless `sts`
confirms `user/abdur-exam-deployer`, and only counts a test as denied if the
error text is an authorization denial — anything else is reported as
`NOT A DENIAL` and flagged in the summary.

The general lesson is the one Scenario B kept teaching: **a check that fails is
not the same as a check that passes the way you wanted.** A "denied" result is
only evidence once you have confirmed who was asking and why they were refused.

<!-- status: DONE -->

### Task 48 (4 marks) — Test your policies

Four actions through the IAM Policy Simulator (console or
`aws iam simulate-principal-policy`): two that must be allowed, two that must be
denied. Screenshots of the results.

Run in the console's (new) IAM Policy Simulator against `abdur-exam-deployer`,
with its one identity policy selected and **Service control policies switched
on**, so the result reflects organization-level controls as well as mine.
Screenshot: `evidence/c1-task48-simulator.png`.

| Service | Action | Resource | Result | Result details |
| --- | --- | --- | --- | --- |
| ECR | `PutImage` | `…:repository/abdur-notes-api` | **Allowed** | Explicit allow in 1 statement(s) |
| ECS | `UpdateService` | `…:service/abdur-exam-cluster/abdur-notes-svc` | **Allowed** | Explicit allow in 1 statement(s) |
| S3 | `DeleteBucket` | `arn:aws:s3:::abdur-any-bucket` | **Denied** | Implicit deny due to no statement(s) matching |
| IAM | `CreateAccessKey` | `…:user/abdur-exam-deployer` | **Denied** | Implicit deny due to no statement(s) matching |

**Why these four.** `DeleteBucket` is the brief's own example of something
outside the policy. `CreateAccessKey` on the deployer itself is the more
important denial: an identity that can mint its own credentials can outlive any
key you revoke, so "cannot extend its own access" is one of the properties least
privilege exists to guarantee. The two allowed actions are the two capabilities
the policy is for.

**Reading the details column.** "Explicit allow in **1** statement" for each
allowed action matches the policy's shape — `PutImage` is granted only by the
repository statement and `UpdateService` only by the service statement, so no
permission is granted twice. "Implicit deny due to no statement(s) matching" is
the same verdict the real CLI calls in task 47 returned as "no identity-based
policy allows", reached here by evaluation rather than by request — and with SCPs
included, so no organization policy is involved in either direction.

#### Scope, and a behaviour of the new simulator worth knowing

The first attempt included a second ECR row — `InitiateLayerUpload` against
`abdur-not-this-repo` — alongside `PutImage` against `abdur-notes-api`. Editing
one row's repository ARN changed the other's as well. The new simulator holds
**one resource ARN per resource type** for a whole simulation, so two actions of
type `repository` cannot be simulated against two different repositories in one
run. Had I not noticed, `PutImage` would have been simulated against the wrong
repository and reported **Denied** — a false negative that reads exactly like a
broken policy.

So each simulation keeps one row per resource type, and the scope test is a
second run with the repository changed and nothing else
(`evidence/c1-task48-simulator-scope.png`): `PutImage`, the same policy, against
`abdur-not-this-repo`.

```
ecr:PutImage   arn:aws:ecr:eu-north-1:750069566598:repository/abdur-notes-api      Allowed  Explicit allow in 1 statement(s)
ecr:PutImage   arn:aws:ecr:eu-north-1:750069566598:repository/abdur-not-this-repo  Denied   Implicit deny due to no statement(s) matching
```

Same identity, same policy, same action. Changing only the repository turns an
explicit allow into an implicit deny, which is the `Resource` element of the
repository statement doing exactly what task 47 claims — reached this time by
policy evaluation, where task 47's run 3 reached it by a real API call.

#### What the simulator cannot tell you

The simulator sends no requests. It evaluates each (action, resource) pair
against the policy documents in isolation, which answers "does this policy allow
this action here?" and not "will this operation work?".

Task 47 is the demonstration. Against the policy's first version — without
`ecr:BatchGetImage` — the simulator would have reported `PutImage` as
**Allowed**, correctly, because it was. The real `docker push` still failed,
because pushing an image is a sequence of API calls and one of them was missing.
The simulator has no notion of which actions a workflow needs, only of whether
each one is individually permitted.

That is why task 47 is proven by a real push and task 48 by the simulator, and
why neither replaces the other: the simulator is fast, safe and exhaustive about
the policy; only the real call is evidence about the operation.

<!-- status: DONE -->

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

#### The image

Pushed by `abdur-exam-deployer` in task 47's run 3 (`evidence/c1-task47-push.txt`),
from the image the Scenario B swarm service was actually running:

```
source image: ghcr.io/rasel-xs/notes-api:v1.0.69
v1.0.69: digest: sha256:e11a0591643dc874a5f5e0464504afb584b32fc17f420d76687256d6bf059bdf size: 2187
```

Screenshot with tag, size and digest, taken with the VPS terminal showing the exam token alongside (`root-vmi3536696-1788282556-1536d427 | Mon Sep 14 22:11:47 CEST 2026`): `evidence/c2-task49-ecr-image.png`.

```
Image tags  v1.0.69
Type        Image
Created at  14 September 2026, 02:05:54 (UTC+06)
Image size  50.48 MB
Digest      sha256:e11a0591643dc87…      <- matches the push output above
```

**`size: 2187` is not the image size.** It is the size in bytes of the manifest
document — the JSON that lists the layers. The image's size is the sum of its
compressed layers, which is what the ECR console reports and what the
screenshot shows.

#### Only one architecture arrived, and the digest changed

Docker printed this after the push:

```
Info -> Not all multiplatform-content is present and only the available single-platform image was pushed
        sha256:88bfcd23eca71d6b785deba7236dbbd59ded3d8aabf0193eca24b4f1beb3c14e -> sha256:e11a0591643dc874a5f5e0464504afb584b32fc17f420d76687256d6bf059bdf
```

Scenario B's CI builds for `linux/amd64` **and** `linux/arm64`, so on GHCR
`v1.0.69` is a multi-platform *index* (`sha256:88bfcd23…`) pointing at two
per-architecture manifests. The VPS had only pulled the amd64 half, so only that
manifest (`sha256:e11a0591…`) could be pushed. Two consequences:

1. **The ECR image is amd64-only.** Fargate's default is `X86_64`, so it runs —
   but task 50's task definition states `runtimePlatform.cpuArchitecture: X86_64`
   explicitly rather than relying on the default. On `ARM64` this image would die
   with `exec format error`, which reads like a corrupt binary rather than an
   architecture mismatch.
2. **The same tag names different digests in the two registries.** GHCR's
   `v1.0.69` is the index; ECR's is the amd64 manifest inside it. The bytes that
   run are identical, but anything pinned by digest will treat them as different
   artefacts. That is worth knowing before arguing, as B5 did, that a version tag
   "names one image": it names one image *per registry*, and a digest is the only
   identifier that survives being copied between them.

<!-- status: DONE -->

### Task 50 (8 marks) — Task definition

Fargate, 256 CPU / 512 memory, with: the ECR container, a port mapping for
3000, **CloudWatch logs via the `awslogs` driver**, a container health check,
and environment variables for the DB connection.

Deliverables: the task definition JSON committed here with the account ID
redacted, a screenshot of the running task, and a screenshot of the app's logs
in CloudWatch Logs.

**Task definition:** [`ecs/abdur-notes-api-taskdef.json`](ecs/abdur-notes-api-taskdef.json),
registered as `abdur-notes-api:1`. The account ID is `<ACCOUNT_ID>` throughout the
committed copy, including inside the secret ARN.

| Requirement | How |
| --- | --- |
| Container from ECR | `…dkr.ecr.eu-north-1.amazonaws.com/abdur-notes-api:v1.0.69`, pinned to `X86_64` — the ECR image is the amd64 manifest only (task 49) |
| Port 3000 | `portMappings` → 3000/tcp, `networkMode: awsvpc` as Fargate requires |
| Logs to CloudWatch | `awslogs` driver → `/ecs/abdur-notes-api`, pre-created with 3-day retention |
| Container health check | `wget --spider http://127.0.0.1:3000/healthz`, interval 10 s, 3 retries, 15 s start period |
| DB connection env | `DATABASE_URL` in `environment`, `PGPASSWORD` in `secrets` — see below |

#### The database, and a password nobody has ever seen

The database is RDS PostgreSQL 16.15 on `db.t3.micro`, single-AZ, 20 GiB gp3,
**not publicly accessible**, in security group `abdur-notes-db-sg` whose only
inbound rule is 5432 from `abdur-notes-app-sg`. The rule names a security group
rather than an address because Fargate tasks get a new IP on every start, and
autoscaling (task 52) adds tasks whose addresses cannot be known in advance.

That the database is private is shown rather than asserted. Its DNS name resolves
from anywhere, but to a VPC-internal address:

```
$ getent hosts abdur-notes-db.c9c4ku2mkinq.eu-north-1.rds.amazonaws.com      # from the VPS
172.31.41.223   abdur-notes-db.c9c4ku2mkinq.eu-north-1.rds.amazonaws.com
```

**Master credentials are managed by Secrets Manager**, so RDS generated the
password and stored it, and no person has read, copied or typed it. The app
needed no change and the image no rebuild to consume it. The pool is built as
`connectionString: process.env.DATABASE_URL || …`, and node-postgres resolves
each connection field as the value parsed from that URL, falling back to
`process.env['PG' + KEY]` (`pg/lib/connection-parameters.js`). So:

```
environment  DATABASE_URL = postgres://notes@abdur-notes-db…:5432/notes?sslmode=no-verify   # no password in it
secrets      PGPASSWORD   = <rds master secret ARN>:password::                             # injected at task start
```

The execution role reads that one secret and nothing else
([`iam/abdur-ecs-task-execution-secret-policy.json`](iam/abdur-ecs-task-execution-secret-policy.json)).
Its `Resource` ends in `-??????`: Secrets Manager appends six random characters
to every secret ARN, and each `?` matches exactly one, so the pattern cannot also
match a different secret whose name begins the same way — which `*` would.

Given that the task 47 push was derailed twice by pasted text landing in a
prompt, a credential that is never handled by a person was worth more here than
it would be in a tidier workflow.

**TLS, honestly.** RDS for PostgreSQL enforces TLS, and Node's default CA store
does not contain the RDS CA, so `sslmode=verify-full` would refuse the
connection. `no-verify` encrypts without verifying the server's certificate. The
RDS console's own connection snippet shows the correct form —
`sslmode=verify-full sslrootcert=global-bundle.pem` — and doing that inside the
container means shipping the bundle in the image. Downloading it at start-up
with busybox `wget` would not verify that download either, so it would be
security theatre. It is done properly in task 53's rebuild instead.

#### Why these settings

- **The health check is repeated in the task definition** because ECS ignores an
  image's `HEALTHCHECK`; only the task definition's check drives task health.
- **It checks `/healthz`, the liveness probe, not `/readyz`.** A failing
  container health check makes ECS replace the task. If the database has a bad
  minute, killing and restarting every app task would turn a database problem
  into an application outage as well. Readiness belongs on the load balancer,
  which can stop *sending* traffic without destroying anything — see task 51.
- **Public IP on.** The default VPC has no NAT gateway, so the task reaches ECR,
  CloudWatch Logs and Secrets Manager over the internet. `abdur-notes-app-sg` has
  no inbound rule at all, so the address accepts nothing; it is outbound only.
- **Launch type `FARGATE`, not a capacity provider,** because the cluster has no
  default capacity provider strategy.

#### It ran, first time

Task `170d12b3c1534ffeaa71aa9b19917367`, log stream
`notes-api/notes-api/170d12b3c1534ffeaa71aa9b19917367`
(`evidence/c2-task50-cloudwatch-logs.png`, `evidence/c2-task50-running-task.png`;
`evidence/c2-task50-task-provisioning.png` is the same task at launch, 00:16
`PROVISIONING` / health `UNKNOWN`; the running screenshot was taken at 00:23. The
task did not take seven minutes to start — its lifecycle shows the image pull
took 2 seconds and `RUNNING` was reached within the same minute, 00:16):

```
2026-09-14T18:16:42.439Z  migrations applied
2026-09-14T18:16:43.066Z  {"level":"info","msg":"listening","host":"ip-172-31-33-76.eu-north-1.compute.internal","port":3000,"version":"v1.0.69","pid":1}
```

The migration script retries every two seconds and logs the database error each
time it fails. It logged none, so the security-group rule, the secret, TLS and
the database all worked on the first connection attempt.

Two further details in the second line matter later. `host` is the task's
private address, which is what will make responses from different tasks
distinguishable behind the load balancer in task 51. And `pid` is 1 even though
the command is `sh -c "… && node src/server.js"`: busybox `sh` exec-replaces
itself for the last command of a list (B2 task 28), so when ECS stops the task
its SIGTERM reaches Node's graceful-shutdown handler directly (B4 task 40).

#### And it stopped cleanly

The standalone task was stopped from the console once task 51's service was
about to replace it (`evidence/c2-task50-stopped-exit-0.png`). Its lifecycle:
running **21 min 48 s**, then stopped, container **exit code 0**.

The exit code is the proof that the claim above holds on ECS. ECS sends SIGTERM,
waits `stopTimeout` (30 s by default), then sends SIGKILL; a killed container
exits **137** (128 + 9). Exit 0 means Node received SIGTERM, closed its server
and exited on its own.

The lifecycle's *Stopped — 35 seconds* is **not** how long the app took to shut
down, and should not be read as "it hit the 30-second timeout". That phase also
covers deprovisioning — detaching and deleting the task's network interface —
which the app plays no part in. Had it been the timeout, the exit code would be
137.

#### Cost of the database

The RDS console offered no free-tier template for this account, and estimated
**$16.27 a month** — about **$0.022 an hour**. It exists for the duration of
tasks 50–54 and is deleted in task 63. Deleted, not stopped: a stopped RDS
instance still bills for storage, and AWS starts it again automatically after
seven days.

<!-- status: DONE -->

### Task 51 (8 marks) — Service behind a load balancer

Deliverable: repeated requests to the ALB showing responses from **different
tasks** — a different container IP or hostname in each response, visible in the
screenshot.

**Result: 12 requests to one ALB DNS name, answered 6 and 6 by two different
Fargate tasks** (`evidence/c2-task51-alb-service.txt`, screenshot
`evidence/c2-task51-different-tasks.png`):

```
ALB: http://abdur-notes-alb-2056595441.eu-north-1.elb.amazonaws.com
request 01  {"status":"ok","version":"v1.0.69","host":"ip-172-31-20-42.eu-north-1.compute.internal"}
request 02  {"status":"ok","version":"v1.0.69","host":"ip-172-31-20-42.eu-north-1.compute.internal"}
request 03  {"status":"ok","version":"v1.0.69","host":"ip-172-31-44-13.eu-north-1.compute.internal"}
...
request 12  {"status":"ok","version":"v1.0.69","host":"ip-172-31-44-13.eu-north-1.compute.internal"}

--- responses per task
   6 ip-172-31-20-42.eu-north-1.compute.internal
   6 ip-172-31-44-13.eu-north-1.compute.internal
```

`host` is `os.hostname()`, which on Fargate is the task's private DNS name. The
same run lists the service's tasks and the target group's view of them, so each
hostname can be tied to a task ID rather than taken on trust:

| Task | AZ | Private IP = hostname | ECS container health | ALB target |
| --- | --- | --- | --- | --- |
| `502cbb9cb5a247419b70bf6709fa95ac` | eu-north-1b | `172.31.44.13` | HEALTHY | healthy |
| `de02599ad47841afa29dad67aec813bd` | eu-north-1a | `172.31.20.42` | UNKNOWN | healthy |

The second task's container health was still `UNKNOWN` while its ALB target
was already `healthy`. That is not a contradiction: the two checks are separate
(see below). The container check has a 15 s start period and had not reported
yet; the ALB check only needs two passes 10 s apart.

Everything was created by [`c2-task51-alb-service.sh`](c2-task51-alb-service.sh),
run from my laptop (*Constraints* §4). The service went from created to stable
in about 70 seconds: tasks started 01:41:14 and 01:41:44, registered as targets
01:41:33 and 01:42:06, service stable before 01:42:24.

#### What was built

```
internet ──80──▶ ALB  abdur-notes-alb ──3000──▶ tasks  abdur-notes-svc ──5432──▶ RDS abdur-notes-db
                 sg abdur-notes-alb-sg          sg abdur-notes-app-sg           sg abdur-notes-db-sg
                 in: 80 from 0.0.0.0/0          in: 3000 from alb-sg ONLY        in: 5432 from app-sg ONLY
```

Each security group admits only the one before it, **by security-group ID, not
by address**. ALB node IPs change without notice, so an IP rule would break;
and "from `sg-03082ef58d9f2db8a`" means "from any network interface that is a
member of the ALB's group", which is exactly the claim. The tasks have public IPs
(no NAT gateway — task 50), but `abdur-notes-app-sg` accepts nothing except the
ALB, so the internet cannot reach a task directly and go around the load
balancer. Before this task the app group had **zero** inbound rules.

| Resource | Setting | Why |
| --- | --- | --- |
| Target group `abdur-notes-tg` | target type **`ip`** | Fargate `awsvpc` tasks have their own ENI and IP; there is no EC2 instance to register |
| | health check **`/readyz`**, HTTP 200 | readiness: it queries the database |
| | interval 10 s, timeout 5 s, healthy 2, unhealthy 2 | a bad task leaves rotation in ~20 s, a new one joins in ~20 s |
| | deregistration delay **30 s** (default 300) | the app's requests take milliseconds and it drains on SIGTERM (task 50); 300 s would add five minutes to every deploy and scale-in, per task |
| ALB `abdur-notes-alb` | internet-facing, all three default subnets (eu-north-1a/b/c) | an ALB needs at least two AZs; tasks may land in any of the three |
| Listener | HTTP :80 → forward to `abdur-notes-tg` | no TLS required by the brief |
| Service `abdur-notes-svc` | desired 2, `FARGATE`, task definition `abdur-notes-api:1` | |
| | same three subnets, `abdur-notes-app-sg`, public IP on | as task 50 |
| | health-check grace period **30 s** | migrations run before the server listens; ALB failures in the first 30 s are ignored. Longer only delays replacing a genuinely broken task |
| | deployment circuit breaker **with rollback** | a revision whose tasks keep failing is rolled back to the last working one (AWS's default threshold here: `BOUNDED_PERCENT` 50) |
| | min healthy 100 %, max 200 % | during a deploy new tasks start before old ones stop, so capacity never drops below 2 |

#### Two health checks, two different jobs

| | Container health check (task definition) | ALB target health check |
| --- | --- | --- |
| Path | `/healthz` — never touches the DB | `/readyz` — pings the DB |
| Question | is the process alive? | should this task get traffic? |
| On failure | ECS **kills and replaces** the task | ALB **stops sending** requests; the task lives |

If the database has a bad minute, `/readyz` fails on every task and the ALB
returns 503s — but nothing is killed, and traffic resumes the moment the database
does. Put `/readyz` in the container check instead and the same database blip
would make ECS restart every task at once, turning a database problem into an
application outage and a thundering herd of reconnecting tasks.

#### Why the split is 6/6 and not "mostly one"

In B4 (task 36), Swarm's routing mesh balanced **per connection**, so a client
reusing one keep-alive connection saw one replica every time. An ALB is a layer-7
proxy that routes **per request**, round-robin by default, regardless of client
connections. Each `curl` here was a separate process. The result alternates
mostly in pairs rather than strictly; the likely reason (not verified) is that
the DNS name resolves to ALB nodes in several AZs and each node keeps its own
round-robin position, so consecutive requests landing on different nodes can
repeat a target.

#### Two tasks running migrations at the same moment

Both tasks run `node db/migrate.js` on start. Every statement in `schema.sql` is
`IF NOT EXISTS` and the tables already existed from task 50, so both were
no-ops. On an empty database, two concurrent `CREATE TABLE IF NOT EXISTS` can
still collide on Postgres's catalog (`pg_type` unique violation); the migration
script's 2-second retry loop would absorb it, but a real system would run
migrations once, as a separate one-off task before the deploy. Noted rather than
fixed, because it did not occur here.

#### Run 1 stopped — correctly

Run 1 (`evidence/c2-task51-alb-service-run1.txt`) stopped at step 1 with
`InvalidPermission.Duplicate`. The port-3000 rule had already been added in the
console, but the script's existence check was wrong:
`IpPermissions[?…].UserIdGroupPairs[?GroupId==x][] | length(@)` filters each
rule's list separately and counts the wrong level, returning 0. The fix is to
flatten first, then filter, then count:
`length(IpPermissions[?…].UserIdGroupPairs[] | [?GroupId==x])`. Because every
step checks its result, the script stopped instead of carrying on with a
half-known state. Run 2 reported the rule as already present and created
everything else.

<!-- status: DONE -->


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

**Result: it scaled 2 → 3 while under load and back to 2 afterwards — and the
new task arrived after the load had already stopped.** That last fact is the
answer to the question, measured rather than estimated.

Script [`c2-task52-autoscaling.sh`](c2-task52-autoscaling.sh); transcript of the
run that scaled `evidence/c2-task52-autoscaling.txt`. Screenshots:
`evidence/c2-task52-cpu-graph.png` (service CPU, both load runs),
`evidence/c2-task52-task-count.png` (Container Insights `RunningTaskCount`),
`evidence/c2-task52-events.png` (*Deployments and events*).
The two graphs are **rendered by CloudWatch itself** with
`aws cloudwatch get-metric-widget-image`, for the fixed window 01:40–02:50 (+06),
from the widget definitions saved beside them
(`evidence/c2-task52-cpu-graph.widget.json`, `evidence/c2-task52-task-count.widget.json`). The
exam token is in each graph's title, and the load runs and the task 54 break are
shaded from the script's own timestamps. They replace console screenshots that
had to be retaken the next day, when the console's relative time range no longer
reached back to the test. The CPU graph also plots RDS CPU for comparison.

#### The policy

```json
{
  "PolicyName": "abdur-notes-cpu50",
  "PolicyType": "TargetTrackingScaling",
  "ScalableTarget": { "ResourceId": "service/abdur-exam-cluster/abdur-notes-svc",
                      "ScalableDimension": "ecs:service:DesiredCount",
                      "MinCapacity": 2, "MaxCapacity": 6 },
  "TargetTrackingScalingPolicyConfiguration": {
    "TargetValue": 50.0,
    "PredefinedMetricSpecification": { "PredefinedMetricType": "ECSServiceAverageCPUUtilization" },
    "ScaleOutCooldown": 60,
    "ScaleInCooldown": 120,
    "DisableScaleIn": false
  }
}
```

Target tracking created, and owns, two CloudWatch alarms:

| Alarm | Condition | Evaluation |
| --- | --- | --- |
| `…-AlarmHigh-…` | `CPUUtilization > 50` | 3 consecutive 1-minute periods |
| `…-AlarmLow-…` | `CPUUtilization < 45` (90 % of target) | **15** consecutive 1-minute periods |

The cooldowns are shortened from the 300 s defaults only to fit the
demonstration in a session. They do not make scale-in fast — the 15-period low
alarm does not change, and it dominates.

`ECSServiceAverageCPUUtilization` is relative to the task's CPU **reservation**:
50 % of a 256-unit (0.25 vCPU) task is 0.125 vCPU.

Container Insights was switched on for `abdur-exam-cluster` just before the test,
because plain `AWS/ECS` metrics have CPU and memory but no task count. It is
switched off again in task 63.

#### Three runs — two did not scale, for different reasons

| Run | Load | Outcome |
| --- | --- | --- |
| 1 (`evidence/c2-task52-autoscaling-run1-c50.txt`) | the brief's `hey -z 5m -c 50`, 01:51–01:56 | **no scale-out.** CPU plateaued at **40 %**. 64,113 responses, all 200, **213 req/s** |
| 2 (`evidence/c2-task52-autoscaling-run2-stopped.txt`) | — | stopped at setup: re-registering the existing scalable target *with tags* is a `ValidationException`. Script now registers only if absent |
| 3 (`…autoscaling.txt`) | `hey -z 5m -c 120`, 02:00:50–02:06:11 | **scaled 2 → 3 → 2.** 81,309 responses, all 200, **270 req/s** |

Run 1 was limited by **the client, not the service**. The fastest response in
the whole run was 185 ms — that is the round trip from Dhaka to Stockholm — so
50 workers can send at most ~50 / 0.234 s ≈ 213 requests per second however idle
the tasks are, and 213 req/s cost the two tasks 40 % CPU. Raising concurrency
raised the rate, not just the connection count, which is what moves CPU.

**It was the app that was working, not the database.** RDS (`db.t3.micro`) CPU
over the same minutes, from CloudWatch:

```
run 1  01:51-01:55   14.6  20.6  21.5  20.9  21.6
run 3  02:01-02:05   24.5  26.2  25.0  24.9  25.2
```

The database had been seeded for this test by a one-off Fargate task running
`node db/seed.js` in the app's own security group — the only thing that can
reach the private RDS instance — with the password injected from Secrets
Manager (5 tenants, 50,000 notes, 150,000 tags in 3.0 s, exit 0;
[`c2-seed-rds.sh`](c2-seed-rds.sh), `evidence/c2-seed-rds.txt`).

`?q=abc` matches within the first few hundred rows of acme's notes, so
`LIMIT 50` stops the "unindexed" scan early; the app's cost is serialising an
8.6 KB JSON response 270 times a second. That matters for what this policy can
and cannot fix — see the last section.

#### Timeline of run 3 — from the transcript's alarm history, scaling activities and service events

| Time (+06) | Event | Source |
| --- | --- | --- |
| 02:00:50 | load starts | script |
| **02:01** | first 1-minute CPU datapoint over 50 % (50.70) | CloudWatch |
| 02:02 – 02:05 | 50.42, 51.03, 50.57, 50.27 | CloudWatch |
| 02:03:15 | newest datapoint visible is still **02:01** | script snapshot |
| **02:06:29** | `AlarmHigh` OK → **ALARM**; scaling activity "Setting desired count to 3" | alarm history, scaling activities |
| **02:06:11** | **load ends** — 18 seconds *before* the alarm | script |
| 02:06:35 | service "has started 1 tasks: e22bffe3…" | service events |
| 02:07:01 | "registered 1 targets" in `abdur-notes-tg` | service events |
| **02:07:20** | "has reached a steady state" — target passed 2 health checks | service events |
| 02:06 | CPU already back to 3.7 % | CloudWatch |

#### Answer: how long from CPU high to a new task serving traffic

**About 6 minutes 20 seconds** — 02:01:00 (start of the first high minute) to
02:07:20 (new target healthy):

| Component | Measured here | Why |
| --- | --- | --- |
| Metric delay | **~2 min** | the 02:01 datapoint was not yet visible at 02:03:15; ECS publishes one-minute service metrics with a lag |
| Alarm evaluation | **3 min** | three consecutive one-minute periods over 50 % |
| (unexplained) | ~1 min | the alarm fired at 02:06:29, a minute after three high datapoints existed. The values were barely over the line (50.3–51.0); my best guess, not verified, is that late-arriving samples revised a datapoint under 50 at an earlier evaluation |
| Scaling activity → task started | **6 s** | 02:06:29 → 02:06:35 |
| Task start → registered as target | **26 s** | Fargate ENI, image pull, `node db/migrate.js`, server listening |
| Target → healthy | **~20 s** | healthy threshold 2 × 10 s interval |

**Why autoscaling cannot save you from a sudden spike:** for six minutes the
existing tasks carry the whole spike alone. A spike that saturates them does its
damage — timeouts, 5xx, queues backing up — in seconds, long before the first
new task exists. Here the extra task started 24 seconds after the load had
already ended, and then ran idle for 17 minutes. Autoscaling follows a sustained
trend; it does not absorb a burst. What does:

- **enough headroom at minimum capacity** (min 2 is the real defence, not max 6);
- **scheduled scaling** before known peaks;
- **a faster signal** — `ALBRequestCountPerTarget` rather than CPU, and step
  scaling with a lower evaluation count — which shortens, but cannot remove, the
  delay;
- **shedding load** — rate limiting per tenant, caching, clamping `?limit` —
  and fixing the expensive query itself. None of those wait for a new task.

And it scales the wrong thing if the database is the bottleneck: more app tasks
send the database *more* concurrent queries, not fewer. Here RDS was at 25 %, so
adding app capacity was right; with a real unindexed scan it would not be.

#### Scale-in

| Time (+06) | Event |
| --- | --- |
| 02:06 | CPU drops to ~3.5 % and stays there |
| 02:23:58 | `AlarmLow` OK → **ALARM** (15 low periods, plus the same metric delay); "Setting desired count to 2" |
| 02:24:01 | "has stopped 1 running tasks: e22bffe3…" |
| 02:24:11 | "deregistered 1 targets", "begun draining connections" (30 s deregistration delay, task 51) |
| 02:24:30 | scaling activity complete |

**Scale-in took 18 minutes 19 seconds** from the load stopping (02:06:11) to the
activity completing (02:24:30). That slowness is deliberate: removing capacity on
a brief dip and adding it straight back ("flapping") is worse than paying for an
idle task for a quarter of an hour.

Two details in the transcript worth not misreading:

- `AlarmLow` was already in `ALARM` at 02:01:58, before the load bit, because the
  idle service sat at 3 % CPU. Nothing happened because the service was already
  at its minimum of 2.
- The alarm names differ between run 1 (`AlarmHigh-a62de06d…`) and run 3
  (`AlarmHigh-7e9f39f5…`). `put-scaling-policy` on an existing policy replaces
  its alarms rather than editing them.

<!-- status: DONE -->

### Task 53 (8 marks) — Deploy from CI/CD

Extend the GitHub Actions pipeline: on push to main, build, push to ECR, update
the ECS service.

Deliverables: a successful pipeline run deploying to ECS, the ECS service
showing the new task definition revision, and the trust policy showing the repo
condition.

**Result: Deploy run #34 deployed commit `1daabd6` (image `v1.0.91`) to
`abdur-notes-svc` as task definition revision `abdur-notes-api:2`, with no AWS
credential stored anywhere — on the third attempt, after two real permission
failures, both diagnosed from the logs and fixed on the AWS side.**

Evidence: `evidence/c2-task53-deploy-ecs.txt` (the successful job's log lines
plus the AWS-side check afterwards), `evidence/c2-task53-attempt1-oidc-denied.txt`,
`evidence/c2-task53-attempt2-ecr-denied.txt`; screenshots
`evidence/c2-task53-pipeline-run.png`, `evidence/c2-task53-ecs-new-revision.png`,
`evidence/c2-task53-trust-policy.png`. Workflow: the `deploy-ecs` job in
[`.github/workflows/deploy.yml`](../.github/workflows/deploy.yml).

#### No keys: OIDC, and a trust policy that names one repository and one branch

GitHub mints a short-lived OIDC token for the job (`permissions: id-token: write`);
`aws-actions/configure-aws-credentials` exchanges it with STS for temporary
credentials of `abdur-github-actions-ecs-deploy`. There is no
`AWS_ACCESS_KEY_ID` secret in the repository and none was ever created.
The account's GitHub OIDC provider already existed (another student created it
on 2026-09-14; an account can only have one per URL) — it was used, not modified.

[`iam/abdur-github-actions-ecs-deploy-trust.json`](iam/abdur-github-actions-ecs-deploy-trust.json):

```json
{
  "Sid": "OnlyGitHubActionsFromRaselXsDevopsExamMainBranchPinnedByOwnerAndRepoId",
  "Effect": "Allow",
  "Principal": { "Federated": "arn:aws:iam::750069566598:oidc-provider/token.actions.githubusercontent.com" },
  "Action": "sts:AssumeRoleWithWebIdentity",
  "Condition": {
    "StringEquals": {
      "token.actions.githubusercontent.com:aud": "sts.amazonaws.com",
      "token.actions.githubusercontent.com:sub": "repo:rasel-xs@39724326/devops-exam@1355109165:ref:refs/heads/main"
    }
  }
}
```

- `aud` stops a token minted for some other cloud or service being replayed here.
- `sub` is the repository **and** the branch. A pull request (`…:pull_request`),
  another branch, a fork, or any other repository presents a different subject
  and is refused. `StringEquals`, not `StringLike` with `*` — a wildcard such as
  `repo:rasel-xs/*` would hand the role to every repository I own.
- The `deploy-ecs` job deliberately has **no `environment:`** — an environment
  changes the subject to `…:environment:<name>`, which this policy would reject.
- The numbers are GitHub's owner and repository IDs (see attempt 1 below), which
  also means a deleted-and-recreated `devops-exam` could not assume the role.

#### Permissions: [`iam/abdur-github-actions-ecs-deploy-policy.json`](iam/abdur-github-actions-ecs-deploy-policy.json)

| Statement (`Sid` is the comment) | Actions | Resource |
| --- | --- | --- |
| `EcrLoginTokenIsRegistryWideAndCannotBeScopedSoResourceIsStar` | `ecr:GetAuthorizationToken` | `*` — as task 47 |
| `PushToTheAbdurNotesApiRepositoryOnly` | layer upload actions, `PutImage`, `BatchGetImage`, `GetDownloadUrlForLayer` | `repository/abdur-notes-api` |
| `TaskDefinitionRegisterAndDescribeHaveNoResourceLevelPermissionsSoResourceIsStar` | `ecs:RegisterTaskDefinition`, `ecs:DescribeTaskDefinition` | `*` — these two actions do not support resource-level permissions |
| `TagOnlyAbdurNotesApiTaskDefinitionsAndOnlyWhileRegisteringThem` | `ecs:TagResource` | `task-definition/abdur-notes-api:*`, condition `ecs:CreateAction = RegisterTaskDefinition` (the task definition carries the `exam-token` tag) |
| `UpdateAndWatchTheAbdurNotesSvcServiceOnly` | `ecs:UpdateService`, `ecs:DescribeServices` | `service/abdur-exam-cluster/abdur-notes-svc` |
| `PassOnlyTheTaskExecutionRoleAndOnlyToEcsTasks` | `iam:PassRole` | `role/abdur-ecs-task-execution-role`, condition `iam:PassedToService = ecs-tasks.amazonaws.com` |

`iam:PassRole` is the one that matters most: registering a task definition names
an execution role, and without the resource and condition the pipeline could
attach *any* role in the account — including an administrator — to a container
it controls.

#### What the job does

1. assume the role via OIDC, print `sts get-caller-identity`;
2. log in to ECR and GHCR;
3. **copy** the image the build job pushed to GHCR into ECR with
   `docker buildx imagetools create`, by digest — **not rebuild it** — and fail
   unless the digests match. Run #34: GHCR and ECR both
   `sha256:6ecd303e0e63c342b7242f61c374602a43673e6a1ba9953ac1e51e447276100c`;
4. register a new revision from the task definition **in git**
   ([`ecs/abdur-notes-api-taskdef.json`](ecs/abdur-notes-api-taskdef.json)), CI
   filling in only the account ID and the image, pinned as `tag@digest`;
5. `update-service`, `wait services-stable`, and then check that the **PRIMARY**
   deployment is the new revision with `rolloutState COMPLETED`. "Stable" alone
   is not success: a deployment-circuit-breaker rollback (task 51) also ends
   stable — on the old revision;
6. through the ALB, require four consecutive `/healthz` answers carrying the new
   version, then `/readyz` (which queries RDS).

Run #34, attempt 3, `deploy-ecs`:

```
"Arn": "arn:aws:sts::750069566598:assumed-role/abdur-github-actions-ecs-deploy/gha-34970646404-3"
GHCR digest: sha256:6ecd303e0e63c342b7242f61c374602a43673e6a1ba9953ac1e51e447276100c
ECR  digest: sha256:6ecd303e0e63c342b7242f61c374602a43673e6a1ba9953ac1e51e447276100c
registered arn:aws:ecs:eu-north-1:750069566598:task-definition/abdur-notes-api:2
primary deployment: arn:aws:ecs:eu-north-1:750069566598:task-definition/abdur-notes-api:2  COMPLETED
healthz: {"status":"ok","version":"v1.0.91","host":"ip-172-31-28-104.eu-north-1.compute.internal"}
healthz: {"status":"ok","version":"v1.0.91","host":"ip-172-31-43-58.eu-north-1.compute.internal"}
{"status":"ready","version":"v1.0.91"}
```

Checked independently from the laptop afterwards: the service's only deployment
is `abdur-notes-api:2`, `PRIMARY`, `COMPLETED`, 2/2 running; revision 2 was
`registeredBy` the assumed GitHub role session; a revision-2 task logged
`migrations applied` and `listening … v1.0.91`.

ECR now shows one tagged image index (`v1.0.91`) and four **untagged** manifests
pushed in the same second. They are not leftovers: an index is a list of
per-platform manifests (amd64, arm64) plus buildx's provenance attestations, and
copying the index copies its children, which carry no tags of their own.

#### The same revision fixes task 50's TLS compromise

Task 50 used `sslmode=no-verify` because the image had no RDS CA. Revision 2's
URL is

```
…/notes?sslmode=verify-full&sslrootcert=/app/certs/rds-global-bundle.pem
```

The Amazon RDS global bundle is committed to the repository
(`scenario-b/app/certs/`, sha256 `e5bb2084…`, fetched once over HTTPS) and copied
into the image. With node-postgres 8.23 / pg-connection-string 2.14,
`verify-full` plus `sslrootcert` sets the CA and keeps both chain and hostname
verification on. A wrong CA or a mismatched hostname would have failed the
migration's connection, the tasks would never have become healthy, and the
circuit breaker would have rolled back to revision 1 — which the job's PRIMARY
check turns into a red run. It stayed green, and `/readyz` answered through
a verified connection.

#### Three attempts — what failed, and why it was not a guess

| Attempt | Failed at | Error | Cause | Fix |
| --- | --- | --- | --- | --- |
| 1 | assume role | `Not authorized to perform sts:AssumeRoleWithWebIdentity` (retried for 2 min) | This repository issues OIDC tokens with the **immutable subject** format (`GET /repos/…/actions/oidc/customization/sub` → `use_immutable_subject: true`, prefix `repo:rasel-xs@39724326/devops-exam@1355109165`). The trust policy expected the name-only `repo:rasel-xs/devops-exam:ref:refs/heads/main`. The IDs were checked against `GET /users/rasel-xs` and `GET /repos/rasel-xs/devops-exam` before changing anything | `sub` rewritten to the ID form |
| 2 | copy image | `not authorized to perform: ecr:GetDownloadUrlForLayer on … repository/abdur-notes-api` | The role could assume and log in, so the trust fix was proven. A cross-registry `imagetools create` does not only write: it checks and reads blobs on the destination. Same lesson as task 47, where `docker push` needed `BatchGetImage` | action added, repository-scoped |
| 3 | — | green | | |

Both fixes were IAM-only, so each retry was **Re-run failed jobs** on the same
run and commit — no new push, and no second production approval for the VPS
job.

#### Before any of that: the run would not start

Run #34 sat on *Pending* with no jobs. Cause: the Scenario B Deploy run
`33905733598` (2026-09-04) had been left at its production-approval gate for
eleven days, holding concurrency group `deploy-main`; every later Deploy run had
been superseded and cancelled without starting — the limitation recorded in
Scenario B task 46, now with a real consequence. It was **rejected** (approving
would have deployed an 11-day-old build to the VPS), and run #34 started within
seconds. The same run's VPS `deploy` job was then approved by hand and succeeded
(3 m 22 s) — the two deploy jobs are independent, and ECS does not wait behind a
human.

<!-- status: DONE -->

### Task 54 (2 marks) — Something is broken, debug it

Break one thing deliberately (wrong target-group port, or a health check path
that 404s), then debug it and write down **the exact order of checks used**.
Deliverables: that list, plus screenshots of the failure and the fixed state.

**The break:** `abdur-notes-tg`'s health check path changed from `/readyz` to
`/readyz-typo` — a path the app does not serve. Nothing else changed: not the
app, the image, the task definition, the security groups. Script
[`c2-task54-break-and-debug.sh`](c2-task54-break-and-debug.sh), transcript
`evidence/c2-task54-break-and-debug.txt`; screenshots
`evidence/c2-task54-failure-events.png` (ECS events during the failure) and
`evidence/c2-task54-fixed-targets.png` (targets healthy after the fix).

#### What actually happened — and why the obvious check said "fine"

| Time (+06) | ALB `/healthz` from outside | ECS service | Targets |
| --- | --- | --- | --- |
| 02:37:50 | 200 | 2/2 | 2 healthy — **path changed** |
| 02:38:37 | **200** | 2/2 | both `unhealthy (Target.ResponseCodeMismatch)` |
| 02:39:00 | **200** | 2 desired / **3 running** / 1 pending | replacement starting before the old one stops |
| 02:39:16 – 02:39:35 | **200** | both original tasks stopped: *"is unhealthy … Health checks failed with these codes: [404]"* | |
| 02:40:53 – 02:41:12 | **200** | *"Amazon ECS replaced 1 tasks due to an unhealthy status"* — twice more | the replacements fail the same check |
| 02:41:39 – 02:41:59 | **200** | the replacements' replacements stopped too | |
| 02:42:13 | — | **fix applied** | |
| 02:42:54 | 200 | 2/2 | both `healthy` — **44 s after the fix** |

Four tasks were stopped in four minutes (`502cbb9c`, `de02599a`, then their
replacements `f236043a`, `db148391`), and **every request from outside returned
200 the whole time.** Two mechanisms explain that, and both matter:

- **ALB fail-open.** When *every* target in a target group is unhealthy, an ALB
  stops trusting the health check and routes to all of them anyway. The app was
  fine, so users were served.
- **ECS acted on the ALB's verdict.** A service attached to a target group
  treats "unhealthy in the target group" as "replace the task", after the 30 s
  grace period. So the replacement loop was real, continuous and invisible from
  the front door — each new task pulling the image, running migrations against
  RDS and being killed again ~40 s later. With a slower-starting app, or a
  database near its connection limit, that loop is what turns into an outage.

The lesson for the debug order: **a green user-facing check does not end the
investigation.** The first check found no symptom; the second found the fault.

#### The exact order of checks used

Outside-in: what the user sees → what the orchestrator says → what the load
balancer says **and why** → its configuration → the app → the network. Each
check either finds the fault or rules out a layer.

| # | Check | Command | Result here | What it ruled in or out |
| --- | --- | --- | --- | --- |
| 1 | **What does a user see?** | `curl $ALB/healthz` ×5 | 200, 200, 200, 200, 200 | no user-visible symptom — *which does not mean healthy* (fail-open) |
| 2 | **What does ECS say?** counts, then service events | `aws ecs describe-services … events` | 2/2, but *"(port 3000) is unhealthy in target-group … codes: [404]"* and *"replaced 1 tasks due to an unhealthy status"* | tasks are being killed; the trigger is the **target group**, not the container or a crash |
| 3 | **What does the ALB think of each target, and why?** | `aws elbv2 describe-target-health` | every target `unhealthy`, reason **`Target.ResponseCodeMismatch`**, *"codes: [404]"* | the reason code picks the layer: *ResponseCodeMismatch* = the app **answered**, with the wrong code. That rules out the network and "app not listening", which would be `Target.Timeout` |
| 4 | **Is the health check asking the right question?** | `aws elbv2 describe-target-groups` | path **`/readyz-typo`**, port traffic-port, matcher 200 | **fault found** — the path |
| 5 | **Is the app itself alive?** | `aws ecs describe-tasks` → container health | both tasks `RUNNING`, container health **`HEALTHY`** (the in-task `/healthz` check) | the app is fine; confirms it is not an app bug |
| 6 | **What does the app answer on the probed path vs the right one?** | `curl $ALB/readyz-typo`, `curl $ALB/readyz` | `{"error":"not found"}` **404** · `{"status":"ready"}` **200** | proves the diagnosis end to end (possible through the ALB precisely because of fail-open; the tasks have no other inbound path) |
| 7 | **Network, only to rule it out** | `aws ec2 describe-security-groups` on the app SG | 3000 from `sg-03082ef58d9f2db8a` still present | nothing changed there — and check 3 had already said so |
| — | **Fix** | `aws elbv2 modify-target-group --health-check-path /readyz` | | |
| — | **Verify** | target health, service steady, requests | both targets `healthy` at 02:42:54, *"has reached a steady state"* 02:42:47, 6 requests answered by 2 tasks | |

Checks 5–7 came after the fault was already found at check 4. On a real
incident I would still run 5 and 6 before changing anything, to confirm the
theory rather than act on the first plausible one; 7 is included to show the
network was ruled out by evidence (the reason code), not assumed.

#### The other suggested break, and how the order would have differed

A **wrong target-group port** (health check port 3001) fails differently: nothing
listens and the app SG does not admit it, so check 3 returns
**`Target.Timeout`**. That sends the investigation to check 7 (security groups)
and the port settings first, and check 6 would show the app answering normally
on 3000. The order stays the same; the reason code in check 3 decides which
later check matters.

<!-- status: DONE -->

---

## C3 — S3 and file uploads (20 marks)

### Task 55 (5 marks) — A private bucket and a presigned upload

A bucket with **all public access blocked** (the default — leave it on), an
endpoint `POST /api/attachments/upload-url` returning a presigned PUT URL, and
an upload through it with `curl -X PUT --upload-file`.

Deliverables: the generated URL, the successful upload, the object in the S3
console.

All four tasks were proved in one run of
[`c3-attachments-demo.sh`](c3-attachments-demo.sh) against the live service
(`v1.0.96`, task definition `abdur-notes-api:3`), transcript
`evidence/c3-attachments-demo.txt`. The script needs only `curl`: **the client
holds no AWS credentials** — the app signs, the client uses the URL, exactly as a
browser would.

Screenshots: `evidence/c3-task55-upload.png` (URL and `HTTP 200`),
`evidence/c3-task55-s3-console.png` (the object).

#### The bucket — `abdur-notes-750069566598` (`evidence/c3-task55-bucket.txt`)

| Setting | Value | Why |
| --- | --- | --- |
| Region | eu-north-1 | same as everything else; bucket names are global, so the account ID is in the name |
| Object ownership | `BucketOwnerEnforced` | ACLs disabled entirely — access is decided by policies only |
| Default encryption | SSE-S3 (AES256), bucket key on | at rest, at no cost |
| Block Public Access | **all four on at creation**; two of them later turned off for task 57 — see there | |
| Tag | `exam-token` | |

#### Who can write: the task role, not the client

The containers run with a new **task role**, `abdur-ecs-task-role`
([`iam/abdur-ecs-task-role-policy.json`](iam/abdur-ecs-task-role-policy.json)):
`s3:PutObject` and `s3:GetObject` on `tenants/*` and `public/*` of this bucket
and nothing else — no `ListBucket`, no `DeleteObject`, no other bucket. Its trust
policy accepts only `ecs-tasks.amazonaws.com` from this account
(`aws:SourceAccount`, `aws:SourceArn`). This is a different role from task 50's
*execution* role: the execution role is used by ECS to pull the image and read
the database secret; the task role is what the application code itself gets.
The CI role's `iam:PassRole` was extended to exactly this one extra role.

A presigned URL is a request signed in advance **with the task role's temporary
credentials** — the `X-Amz-Credential` in the URL begins `ASIA…` (an STS session
key), and `X-Amz-Security-Token` carries the session. The URL grants what that
role may do, for that one key and method, until it expires.

#### The endpoint — [`scenario-b/app/src/attachments.js`](../scenario-b/app/src/attachments.js)

`POST /api/attachments/upload-url` with `{"filename": "...", "visibility": "private"|"public"}`
returns a presigned **PUT** valid for **300 s**. The key is chosen by the
server, never by the client: `tenants/<tenant>/private/<uuid>-<name>`, the
filename reduced to a safe basename (`"../../etc/passwd report.pdf"` becomes
`passwd_report.pdf` — checked in an offline test before deploying).

From the transcript:

```
$ curl -X POST $ALB/api/attachments/upload-url -H 'X-Tenant: acme' -d '{"filename":"acme-invoice-001.txt"}'
{"key":"tenants/acme/private/f1dd8c56-…-acme-invoice-001.txt","visibility":"private","method":"PUT",
 "url":"https://abdur-notes-750069566598.s3.eu-north-1.amazonaws.com/tenants/acme/private/f1dd8c56-…-acme-invoice-001.txt
        ?X-Amz-Algorithm=AWS4-HMAC-SHA256&X-Amz-Content-Sha256=UNSIGNED-PAYLOAD
        &X-Amz-Credential=ASIA…%2F20260915%2Feu-north-1%2Fs3%2Faws4_request
        &X-Amz-Date=20260915T133601Z&X-Amz-Expires=300&X-Amz-Security-Token=…
        &X-Amz-Signature=1b9fec62…&X-Amz-SignedHeaders=host&x-id=PutObject","expiresInSeconds":300}

$ curl -X PUT --upload-file acme-invoice-001.txt '<the URL above>'
HTTP 200
```

**A trap avoided.** AWS SDK for JavaScript v3 now adds a CRC32 checksum of the
body to `PutObject` by default. For a *presigned* PUT there is no body when the
URL is made, so the URL would carry a checksum that no real file matches and
`curl --upload-file` would be refused. The S3 client is built with
`requestChecksumCalculation: 'WHEN_REQUIRED'`; the offline test confirmed the
generated URL has no checksum parameters, and the upload returned 200.

<!-- status: DONE -->

### Task 56 (4 marks) — Presigned download and expiry

`GET /api/attachments/:key/download-url` returning a presigned GET URL with a
**60 second** expiry. Open it (works), wait 61 seconds, open it again and
screenshot **the exact XML error** S3 returns. Also show a plain unsigned
request to the object → AccessDenied.

**Question for ANSWERS.md:** if a user posts their presigned URL in a public
Telegram group, what can strangers do and for how long? Give **two different**
ways to reduce the risk, and say which one you would actually implement and why.

Screenshot: `evidence/c3-task56-expired-xml.png`.

`GET /api/attachments/:key/download-url` — the key URL-encoded into one path
segment (`tenants%2Facme%2Fprivate%2F…`) — returns a presigned **GET** with
`X-Amz-Expires=60` and an `expiresAt`:

```
{"key":"tenants/acme/private/f1dd8c56-…-acme-invoice-001.txt","method":"GET",
 "url":"https://…/tenants/acme/private/f1dd8c56-…?…&X-Amz-Date=20260915T133603Z&X-Amz-Expires=60&…",
 "expiresInSeconds":60,"expiresAt":"2026-09-15T13:37:03.846Z"}

--- open it now (works)
acme invoice 001 -- private to acme -- Tue Sep 15 19:36:01 +06 2026
[HTTP 200]

waiting 61 seconds...

--- open the SAME URL again after 61 s -- S3's exact error
<?xml version="1.0" encoding="UTF-8"?>
<Error><Code>AccessDenied</Code><Message>Request has expired</Message><X-Amz-Expires>60</X-Amz-Expires><Expires>2026-09-15T13:37:03Z</Expires><ServerTime>2026-09-15T13:37:08Z</ServerTime><RequestId>YEHRM4KPC60J4SYE</RequestId><HostId>YcP79Hs4…</HostId></Error>
[HTTP 403]

--- a plain, unsigned request for the same object
<?xml version="1.0" encoding="UTF-8"?>
<Error><Code>AccessDenied</Code><Message>Access Denied</Message><RequestId>M0DAY635TZA24HEE</RequestId><HostId>JIkO9UGI…</HostId></Error>
[HTTP 403]
```

The two denials are different on purpose: *Request has expired* means the
signature was valid and only the clock refused it (S3 even reports the expiry and
its own time — 13:37:03 vs 13:37:08); *Access Denied* with no signature means
nobody was identified at all, and the bucket grants anonymous users nothing
under `tenants/`.

#### Question: a presigned URL posted in a public Telegram group

**What strangers can do:** anyone who clicks it can **download that one object**
— only that key, only `GET` — from anywhere, with no login, **until it
expires: at most 60 seconds after it was signed** (and sooner if the task role's
temporary credentials that signed it expire first; a URL never outlives its
signing session). They cannot list the bucket, upload, delete, change the key,
or mint new URLs — the URL contains no secret key, only a signature over this
one request. But expiry limits *access*, not *copies*: whoever downloaded it in
those 60 seconds keeps the file and can re-post it forever. A presigned URL is a
**bearer token** — possession is permission.

**Two different ways to reduce the risk:**

1. **Make the token nearly worthless when leaked — very short TTL, signed per
   click.** The URL is created only when the user clicks "download", for 60 s or
   less, and never stored or emailed. A leak is then a race measured in seconds.
   Cheap, no extra infrastructure; already implemented. Weakness: during the
   window, anyone gets the file.
2. **Do not hand out S3 URLs for private files at all — download through the
   application.** `GET /api/attachments/:key` checks the logged-in user and tenant
   on **every** request and streams the object from S3 (or returns a URL only to
   an authenticated session, never in a shareable form). A leaked link then
   needs the victim's session too, every access is logged per user, and access
   can be revoked instantly. Weakness: file bytes flow through the app — more
   bandwidth and CPU on the tasks, and no direct-from-S3 speed.

(A third, blunter lever exists for emergencies: removing `s3:GetObject` from the
task role, or revoking its sessions, invalidates **every** outstanding URL at
once — useful after a leak, not as a design.)

**Which I would implement:** option 2 for `tenants/*/private/*`, keeping
presigned URLs for **uploads** and for `public/*`. For private tenant documents
the question that matters is "is *this* person allowed *now*?", and only an
authenticated request can answer it each time; a short TTL just shortens the
window in which the answer is "anyone". The bandwidth cost is acceptable for the
small documents this app stores. The 60 s TTL stays as defence in depth for any
URL that is issued.

<!-- status: DONE -->

### Task 57 (6 marks) — Two access patterns in one bucket

- `tenants/<tenant>/private/*` — presigned only, never public
- `public/*` — anyone can read with a plain URL, no signing

Prove all three, one screenshot each: plain URL to `public/` works; plain URL to
`tenants/acme/private/` is AccessDenied; presigned URL to that same private file
works.

Screenshots: `evidence/c3-task57a-public-plain-200.png`,
`evidence/c3-task57b-private-plain-denied.png`,
`evidence/c3-task57c-private-presigned-200.png` — taken on the exam VPS from one
run of the same script (15:51 CEST), so each shows all three results; the file
name says which one it is evidence for.

```
--- 57a. plain URL to public/ -- no signature, anyone
$ curl https://abdur-notes-750069566598.s3.eu-north-1.amazonaws.com/public/acme/b2142f66-…-acme-logo.txt
acme public logo placeholder -- Tue Sep 15 19:36:01 +06 2026
[HTTP 200]

--- 57b. plain URL to tenants/acme/private/ -- no signature
<Error><Code>AccessDenied</Code><Message>Access Denied</Message>…</Error>
[HTTP 403]

--- 57c. presigned URL to that same private file
acme invoice 001 -- private to acme -- Tue Sep 15 19:36:01 +06 2026
[HTTP 200]
```

#### How the two patterns coexist — and a conflict with task 55

The brief asks for all public access blocked (task 55) **and** a prefix anyone can
read with a plain URL (task 57). With Block Public Access fully on, S3 refuses
*any* public bucket policy, so both cannot be literally true of one bucket
accessed directly.

**First choice: keep every block on and publish `public/*` through CloudFront**
with Origin Access Control — the bucket would grant read only to one
CloudFront distribution, and "a plain URL" would be the CloudFront URL. The OAC
was created, but the distribution was refused
(`evidence/c3-task57-cloudfront-create.txt`):

```
An error occurred (AccessDenied) when calling the CreateDistributionWithTags operation:
Your account must be verified before you can add new CloudFront resources.
```

— the same account-level "verification in progress" state that blocked
CloudShell (*Constraints* §4), not an IAM permission. The unused OAC was deleted
immediately and no CloudFront resource of mine exists.

**What was built instead** (`evidence/c3-task57-bucket-policy.txt`): on this
bucket only, the two **policy** blocks were turned off and the two **ACL**
blocks left on:

```
BlockPublicAcls: true       IgnorePublicAcls: true        <- still on: no object can be made public by ACL
BlockPublicPolicy: false    RestrictPublicBuckets: false  <- off: allows the one statement below
```

[`s3/abdur-notes-bucket-policy.json`](s3/abdur-notes-bucket-policy.json):

| Sid | Effect | What |
| --- | --- | --- |
| `AnyoneMayReadObjectsUnderPublicPrefixOnlyNothingElse` | Allow `*` | `s3:GetObject` on `arn:aws:s3:::abdur-notes-750069566598/public/*` — no `ListBucket`, no other prefix |
| `RefuseAnyRequestThatIsNotTls` | Deny `*` | every `s3:*` when `aws:SecureTransport` is `false` |

S3's own verdict afterwards was `get-bucket-policy-status` → `"IsPublic": true`
— stated rather than hidden: the bucket **is** public, for `public/*`, and the
proofs above show that `tenants/*` is not. `tenants/…/private/*` needs no
statement at all: nothing grants anonymous access there, so the default implicit
deny applies (57b), while a presigned URL carries the task role's identity, which
is allowed (57c).

Uploads to `public/` still go through a presigned PUT from the app; the policy
opens reading only. With a verified account I would move `public/*` behind
CloudFront and turn all four blocks back on.

<!-- status: DONE -->

### Task 58 (5 marks) — Tenant isolation

`acme` must never read `globex`'s files even knowing the key. The check happens
**in application code, before anything is signed**. Prove it: as `acme`, request
a presigned URL for a `globex` key, and screenshot the 403.

Screenshot: `evidence/c3-task58-cross-tenant-403.png`.

```
globex's key (acme knows it): tenants/globex/private/22388173-980c-42b5-8557-c799fc8146f0-globex-payroll.txt

$ curl $ALB/api/attachments/<globex key>/download-url -H 'X-Tenant: acme'
{"error":"forbidden: this key does not belong to your tenant"}
[HTTP 403]

control -- the owner asks for the same key:
  globex -> [HTTP 200] (a URL was signed)
```

The object exists (globex uploaded it in the same run), and the control request
proves the key is valid — the 403 is about *who is asking*, not a missing file.

#### Why the check has to be in application code

Every tenant's request is served by the same containers with the same task role,
and that role may read `tenants/*`. **IAM cannot tell acme from globex** — to AWS
both are `abdur-ecs-task-role`. So the only place that knows which tenant is
asking is the app, and it must decide **before** calling the signer: once a URL
exists, S3 will honour it for anyone holding it. `keyBelongsToTenant()` in
[`attachments.js`](../scenario-b/app/src/attachments.js) allows a key only if it
starts with `tenants/<caller>/` or `public/<caller>/`, and rejects `..`, `//`,
a leading `/` and oversized keys — so `tenants/acme/../globex/private/x.pdf` is
also refused (403 in the offline test). A refusal is logged as a `warn` line with
the tenant and the key, and no URL is returned.

**The honest limit:** the tenant is taken from the `X-Tenant` header, which any
client can set — `-H 'X-Tenant: globex'` would pass this check. Isolation is only
as strong as tenant identification. That is exactly C4 task 62.3, where the
tenant must come from the `Host` header set by the proxy and a client-supplied
`X-Tenant` must be overwritten.

<!-- status: DONE -->

---

## C4 — Multi-tenancy with subdomains (26 marks)

No TLS required; HTTP is fine. One application instance serves every tenant,
routing on the `Host` header. A customer can also bring their own domain.

A real domain is needed. A cheap `.xyz`, DuckDNS or nip.io all count.
`/etc/hosts` simulation is allowed but **loses 3 marks** and must be declared.

#### Route taken — real DNS, no `/etc/hosts`

| Need | What I used | Why it counts as real DNS |
| --- | --- | --- |
| Wildcard tenant domain | **`*.abdur.169.58.246.108.nip.io`** | nip.io is a public DNS service that answers *any* name ending in `<ip>.nip.io` with that IP. `acme.abdur.169.58.246.108.nip.io` resolves to the VPS from anywhere on the internet — checked from the VPS (`getent hosts`) and from my laptop in Dhaka (`curl`). The `abdur.` label keeps my names apart from other students on the same shared IP |
| A customer's own domain (61) | **`notes.globex-corp.169.58.246.108.sslip.io`** | sslip.io is a **different** public DNS service with the same behaviour — a genuinely separate domain name that a tenant can "bring", pointed at the VPS |

Nothing was simulated with `/etc/hosts`, on the VPS or on the client.

#### Where it runs, and why port 8141

C4 runs on the **exam VPS** (169.58.246.108): nginx 1.24 in front of the
Scenario B swarm service `abdur_notes_app` (published on 3140) and its Postgres
— not on AWS, so no ALB (which cannot have a nip.io address — it has no fixed
IP) and no extra cost.

A read-only recon first (`c4-vps-recon.sh`, `evidence/c4-vps-recon.png`) found
that **port 80 is shared**: its `default_server` belongs to another student's
site (`sites-enabled/emaapp`). Task 62.1 needs *unknown* hostnames to reach **my**
default server, which on port 80 would mean taking theirs. So everything listens
on **8141**, where the default server is mine, and every name in the config is
prefixed `abdur_` because nginx's `http{}` block is shared too. The URLs carry
`:8141`; the brief requires HTTP, not port 80. The recon also showed the VPS
database had no tenants at all, so `acme` and `globex` were created through the
new provisioning endpoint (task 60) by the installer.

| Piece | File |
| --- | --- |
| nginx config (two server blocks on 8141) | [`c4/abdur-c4.conf.template`](c4/abdur-c4.conf.template), rendered to `/etc/nginx/sites-available/abdur-c4` |
| app: host routing, provisioning, domains | [`scenario-b/app/src/tenancy.js`](../scenario-b/app/src/tenancy.js), [`db/schema.sql`](../scenario-b/app/db/schema.sql) |
| installer | [`c4-install.sh`](c4-install.sh) — `nginx -t` must pass before any reload; a failed test restores the previous file |
| proofs | [`c4-demo.sh`](c4-demo.sh) |

The same image runs everywhere. Host mode switches on only where
`TENANT_BASE_DOMAIN` is set (the VPS service); the ECS deployment stays in header
mode — checked through the ALB after the deploy: no header → 400, `acme` → 200,
unknown → 404, cross-tenant attachment → 403, reserved slug → 422.

**Installing did not go cleanly the first time**, and both failures are kept:

1. **Install run 1 stopped at `nginx -t`**
   (`evidence/c4-install-run1-nginx-test-failed.txt`): *"location" directive is
   not allowed here*. The template's own header comment spelled the placeholder
   names, the renderer substituted inside the comment too, and the three-line
   `/metrics` rule landed outside any server block. The safety net worked — the
   previous state was restored and **nginx was not reloaded**, so no other
   student's site was touched. Fixed by removing the names from the comment and
   making the renderer count placeholders first and refuse to write a config
   still containing `@@`. Run 2 installed cleanly (`evidence/c4-install-run2.txt`).
2. **Demo run 1's "fixed" checks for 62.3 and 62.4 ran inside the nginx reload
   window** — see 62.3 below.

### Task 59 (8 marks) — Wildcard DNS and Host-based routing

Prove: `acme.<domain>/api/notes` returns acme's notes; `globex.<domain>` returns
different notes; `doesnotexist.<domain>` returns a clean 404 rather than a
crash; and `docker ps` / `systemctl status` shows only **one** app instance
serving all of them.

Screenshot `evidence/c4-task59-host-routing.png`; text `evidence/c4-demo-run1.txt`.

```
$ curl http://acme.abdur.169.58.246.108.nip.io:8141/api/notes?limit=3
  titles: "Welcome to Acme Corp" "Getting started" "Your address"            [HTTP 200]
$ curl http://globex.abdur.169.58.246.108.nip.io:8141/api/notes?limit=3
  titles: "Welcome to Globex Corporation" "Getting started" "Your address"   [HTTP 200]
$ curl http://doesnotexist.abdur.169.58.246.108.nip.io:8141/api/notes
{"error":"unknown tenant: doesnotexist"}                                     [HTTP 404]

acme / globex / doesnotexist .abdur.169.58.246.108.nip.io  -> 169.58.246.108   (all three)

$ docker service ls --filter name=abdur_notes_app
abdur_notes_app   replicated   1/1   ghcr.io/rasel-xs/notes-api:v1.0.100   *:3140->3000/tcp
$ docker service ps abdur_notes_app --filter desired-state=running
abdur_notes_app.1   ghcr.io/rasel-xs/notes-api:v1.0.100   vmi3536696   Running 4 minutes ago
```

Different notes for different hostnames, from **one** container: the swarm
service was scaled from 3 replicas to 1 by the installer precisely so this shows
a single instance, not a per-tenant deployment. `doesnotexist` resolves to the
same server (wildcard DNS cannot know which tenants exist) and gets a JSON 404 —
the process is unaffected.

#### How one request finds its tenant

```
acme.abdur.169.58.246.108.nip.io:8141
      │  DNS (nip.io wildcard) → 169.58.246.108
      ▼
nginx :8141  server_name "~^(?<abdur_slug>[a-z0-9][a-z0-9-]{1,30}[a-z0-9])\.abdur\.169\.58\.246\.108\.nip\.io$"
      │  proxy_set_header X-Tenant $abdur_host_tenant;   ← "acme", derived from Host, ALWAYS set
      ▼
abdur_notes_app (1 replica) → resolveTenant: slug → tenant id → every query WHERE tenant_id = $n
```

The regex in `server_name` is the wildcard server block. The tenant name is
extracted by an `abdur_`-prefixed `map $host` with the same pattern, so the
value handed to the app can only come from the hostname. A second
`listen 8141 default_server` block takes every other hostname and sends **no**
`X-Tenant` at all (tasks 61 and 62.1).

<!-- status: DONE -->

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

Screenshot `evidence/c4-task60-provision.png`; text `evidence/c4-demo-run1.txt`.

```
before: nginx config last changed 2026-09-15 17:29:17

$ curl -X POST http://abdur.169.58.246.108.nip.io:8141/api/tenants -d '{"slug":"initech","name":"Initech LLC"}'
{"tenant":{"id":3,"slug":"initech","name":"Initech LLC"},
 "url":"http://initech.abdur.169.58.246.108.nip.io:8141/","seededNotes":3,"s3Prefix":"tenants/initech/"}
[HTTP 201]

$ curl http://initech.abdur.169.58.246.108.nip.io:8141/api/notes      <- no DNS or nginx change in between
  titles: "Welcome to Initech LLC" "Getting started" "Your address"     [HTTP 200]
after:  nginx config last changed 2026-09-15 17:29:17

  slug www        -> {"error":"slug \"www\" is reserved"}  [HTTP 422]
  slug api        -> {"error":"slug \"api\" is reserved"}  [HTTP 422]
  slug admin      -> {"error":"slug \"admin\" is reserved"}  [HTTP 422]
  slug acme.evil  -> {"error":"slug must not contain dots (it would become a nested subdomain)"}  [HTTP 422]
```

Provisioned and served within the same second; the nginx file's modification
time is identical before and after.

#### What `POST /api/tenants` does

In one transaction: insert the tenant (`ON CONFLICT (slug) DO NOTHING` → **409**
if taken, so two simultaneous requests for one slug cannot both win), insert
three seed notes, commit; return the tenant, its URL, the seed count and its S3
prefix. **The S3 prefix needs no creation step**: S3 has no directories —
`tenants/initech/` exists the moment the first object is written under it, and
the bucket policy and task role (C3) already cover `tenants/*`. Creating an
empty marker object would only add a failure mode. (On the VPS there are no AWS
credentials at all — deliberately, it is a shared root box — so the VPS
deployment reports the prefix it will use; uploads work on the ECS deployment.)

#### Why no DNS or nginx change was needed

- **DNS:** the record is a wildcard. nip.io answers every
  `<anything>.abdur.169.58.246.108.nip.io` with the VPS's IP, so `initech` resolved
  before it existed — as does `doesnotexist`. With a registered domain this is one
  `*.domain A <ip>` record, created once.
- **nginx:** the server block matches a **pattern**, not a list of names, and
  passes whatever label it captured. It never needs to know which tenants exist.
- **The only place a tenant exists is the database**, so creating one is an
  `INSERT`. The app looks the slug up on every request (cached after the first).

The flip side is task 59's `doesnotexist`: because DNS and nginx accept every
label, the application must be the thing that says "no such tenant".

#### What `slug` needs — implemented in `validateSlug()`

A slug becomes a DNS label, an S3 key prefix and a metrics label at once:

| Rule | Why | Example refused |
| --- | --- | --- |
| 3–32 characters of `a-z 0-9 -` | DNS label characters; bounded length | `a_b`, `ab` |
| starts and ends with a letter or digit | a DNS label cannot begin or end with `-` | `-acme`, `acme-` |
| **no dots** | `acme.evil` would be a *nested* subdomain: either it never matches the one-label regex, or a looser pattern would serve it as a tenant while `evil.<base>` looks like a different one | `acme.evil` |
| lowercase only | hostnames are case-insensitive; `Acme` and `acme` must not be two tenants | `Acme` |
| no `--` | `xn--…` labels are punycode — the way to register a look-alike (`аcme` with a Cyrillic а) | `xn--80ak6aa92e` |
| **not reserved** | `www`, `api`, `admin`, `login`, `billing`, `support`, `status`… are either names users trust (a phishing page on `admin.<base>` or `login.<base>` looks official) or names the service needs for itself later (`api`, `mail`, `metrics`, `grafana`) | `www`, `api`, `admin` |

The blocklist has 51 entries. Uniqueness is the database's job, not validation's:
`tenants.slug` is `UNIQUE`.

<!-- status: DONE -->

### Task 61 (6 marks) — Custom domain

`notes.theircompany.com` instead of `theircompany.<domain>`. A real second
domain scores full marks; state clearly which route was taken.

**Route taken: a real second domain** — `notes.globex-corp.169.58.246.108.sslip.io`,
on the public sslip.io DNS service (separate from the nip.io tenant domain),
attached to tenant `globex`. Screenshot `evidence/c4-task61-custom-domain.png`;
text `evidence/c4-demo-run1.txt`.

```
notes.globex-corp.169.58.246.108.sslip.io -> 169.58.246.108

1. globex claims it (request arrives on globex's own subdomain)
$ curl -X POST http://globex.abdur.169.58.246.108.nip.io:8141/api/domains -d '{"domain":"notes.globex-corp.169.58.246.108.sslip.io"}'
{"domain":"notes.globex-corp.169.58.246.108.sslip.io","verified":false,"tenant":"globex",
 "next":"point an A record for … at 169.58.246.108, then POST /api/domains/…/verify"}   [HTTP 201]

2. before verification the domain serves nothing
$ curl http://notes.globex-corp.169.58.246.108.sslip.io:8141/api/notes
<h1>Domain not configured</h1> …                                                        [HTTP 404]

3. verify: the app resolves the name and checks it points here
$ curl -X POST http://globex.abdur.169.58.246.108.nip.io:8141/api/domains/notes.globex-corp.169.58.246.108.sslip.io/verify
{"domain":"…","verified":true,"addresses":["169.58.246.108"]}                           [HTTP 200]

4. now the custom domain is globex
$ curl http://notes.globex-corp.169.58.246.108.sslip.io:8141/api/notes
  titles: "Welcome to Globex Corporation" "Getting started" "Your address"               [HTTP 200]
```

#### How it works

- The custom hostname does **not** match the subdomain regex, so it lands on the
  `default_server` block, which sends **no** `X-Tenant`. The app's `gate`
  middleware looks the hostname up:
  `SELECT … FROM tenant_domains d JOIN tenants t … WHERE d.domain = $1 AND d.verified`.
  Found → that tenant; not found → the "domain not configured" page (62.1).
- A domain is **claimed** by the tenant whose own hostname the request arrived
  on — the tenant comes from nginx, not from the request body — and stays
  unusable until **verified**: the app resolves its A record and requires the
  VPS's IP among the answers. Claiming without controlling DNS gets you nothing.
- The lookup is **not cached**. A domain removed or re-assigned must stop serving
  the old tenant immediately; a hostname-keyed cache is a classic place for one
  tenant's data to be served under another's name.
- nginx needed **no change** for this domain either: the default server block
  already accepts any hostname.

**Honest limits.** Verification here checks only that DNS points at the service,
which proves the claimer controls DNS *or* that someone else already pointed it
here — a production service would require a per-claim TXT token
(`_verify.notes.theircompany.com TXT <random>`) so that pointing DNS is not enough
on its own. There is no user authentication in this app at all, so "the tenant
whose hostname the request arrived on" is the whole authorisation model. And a
real custom domain would need a TLS certificate per hostname (e.g. on-demand ACME)
— not required by this brief.

<!-- status: DONE -->

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

All four points were **demonstrated**, not only answered.

#### 62.1 — DNS pointed at us before the domain was added or verified

Screenshot `evidence/c4-task62-1-domain-not-configured.png`.

```
$ curl http://notes.unknowncompany.169.58.246.108.sslip.io:8141/
<!doctype html><title>Domain not configured</title>
<h1>Domain not configured</h1>
<p><b>notes.unknowncompany.169.58.246.108.sslip.io</b> is not connected to any workspace on this service.</p>
<p>If this is your domain, add it in your workspace settings and verify it.</p>
[HTTP 404]
(same for /api/notes)
```

**What a visitor would see without the fix** depends on the fallback, and every
common fallback is bad: port 80's catch-all on this VPS is another student's
site, so they would see an unrelated app; a naive "no tenant → default tenant"
serves **someone else's data**; an app that assumes a tenant exists crashes with
a 500. The fix is that unknown hostnames have a defined, boring answer:
nginx's `default_server` sends no tenant, and the app's `gate` runs before
**every** route (only `/healthz`, `/readyz`, `/metrics` are exempt) and answers
404 "domain not configured" unless the hostname is a **verified** custom domain.
Task 61 step 2 shows the same page for a domain that *was* claimed but not yet
verified — the case in the question exactly. `/` is deliberately not exempt, so
the home page gets the page too, not the app's banner.

#### 62.2 — two tenants claim the same domain

Screenshot `evidence/c4-task62-2-duplicate-domain-409.png`.

```
$ curl -X POST http://acme.abdur.169.58.246.108.nip.io:8141/api/domains -d '{"domain":"notes.globex-corp.169.58.246.108.sslip.io"}'
{"error":"domain notes.globex-corp.169.58.246.108.sslip.io is already claimed by another workspace","constraint":"tenant_domains_pkey"}
[HTTP 409]

                       Table "public.tenant_domains"
 domain     | text    | not null
 tenant_id  | integer | not null
 verified   | boolean | not null | false
Indexes:
    "tenant_domains_pkey" PRIMARY KEY, btree (domain)
Foreign-key constraints:
    "tenant_domains_tenant_id_fkey" FOREIGN KEY (tenant_id) REFERENCES tenants(id)
```

**What stops the second tenant is the database, not an `if`.** `domain` is the
table's primary key, so a second row for the same hostname is impossible no
matter how the requests arrive — even two claims racing through different app
replicas, where a "check, then insert" in application code would let both pass
the check. The app catches the unique violation (`23505`) and returns 409 with
the constraint name. The message says "another workspace" without naming it:
which tenant owns a domain is not acme's business. Claims are only by the tenant
the request arrived as, so acme cannot claim *on behalf of* globex either.

#### 62.3 — the tenant header can be faked

Screenshot `evidence/c4-task62-3-header-spoof.png`; text
`evidence/c4-demo-run2-623-624.txt`.

The brief's test was run against a deliberately **buggy** nginx config first —
the kind of "handy override" that gets added for debugging:
`map $http_x_tenant $abdur_tenant_buggy { "" $abdur_host_tenant; default $http_x_tenant; }`
(use the client's header when there is one). Then against the real config:

```
(1) BUGGY   proxy_set_header X-Tenant $abdur_tenant_buggy;
$ curl -H 'X-Tenant: globex' http://acme.abdur.169.58.246.108.nip.io:8141/api/notes      (x3)
  try 1: "title":"Welcome to Globex Corporation"
  try 2: "title":"Welcome to Globex Corporation"
  try 3: "title":"Welcome to Globex Corporation"
  ^ acme's hostname, globex's notes: VULNERABLE

(2) FIXED   proxy_set_header X-Tenant $abdur_host_tenant;
$ curl -H 'X-Tenant: globex' http://acme.abdur.169.58.246.108.nip.io:8141/api/notes      (x3)
  try 1: "title":"Welcome to Acme Corp"
  try 2: "title":"Welcome to Acme Corp"
  try 3: "title":"Welcome to Acme Corp"
```

**What stops it:** `proxy_set_header X-Tenant $abdur_host_tenant` **replaces** any
`X-Tenant` the client sent — nginx does not append to or pass through a header it
sets — and `$abdur_host_tenant` is derived only from `Host` through the regex.
On the default server it is set to `""`, which makes nginx send no `X-Tenant` at
all, so a client cannot inject one on a custom or unknown domain either.

Why it is a real vulnerability even though this app has no login: in any real
multi-tenant service the user's session is bound to *their* hostname
(`acme.<domain>` cookies). If the backend trusts a header over the hostname,
acme's logged-in user can act on globex's data with one extra header — the
authentication check passes (valid acme session) and the tenant check reads the
attacker's header.

**Demo run 1 got this wrong, and it is recorded** (`evidence/c4-demo-run1.txt`).
Its "(2) FIXED" half printed globex's notes under a label saying acme. Checked
from the laptop minutes later, three requests each returned acme — the config was
right, the *test* was wrong: `systemctl reload nginx` only sends the signal and
returns, and until the master has started new workers and told the old ones to
stop accepting, an old worker still running the previous (buggy) config can take
the next connection. The demo curled inside that window. The installer now waits
for old workers to finish shutting down and settles before returning, and the
demo sends three separate requests, because one answer is not proof. Run 2 above
is the result.

**Remaining exposure, stated:** port 3140 (the swarm routing mesh) is published
on all interfaces, so a client can reach the app directly, skip nginx, and send
any `X-Tenant`. With no authentication that grants nothing a visitor to
`globex.<domain>` does not already have; with authentication the fix is to stop
publishing 3140 publicly (host firewall allowing only 127.0.0.1) or to have nginx
add a secret the app requires before trusting the header.

#### 62.4 — one more isolation bug in my own code: `/metrics` on tenant hostnames

Screenshot `evidence/c4-task62-4-metrics-leak.png`; text
`evidence/c4-demo-run2-623-624.txt`.

B3 labelled every request metric with `tenant`, and `/metrics` is an ordinary
route on the app. In host mode that means **every tenant's hostname serves every
tenant's metrics**:

```
(1) BUG
$ curl http://acme.abdur.169.58.246.108.nip.io:8141/metrics | grep 'tenant="globex"'
http_requests_total{route="/api/notes",method="GET",tenant="globex",status="200",app="notes-api"} 13
http_requests_total{route="/api/domains",method="POST",tenant="globex",status="201",app="notes-api"} 1
http_requests_total{route="/api/domains/:domain/verify",method="POST",tenant="globex",status="200",app="notes-api"} 1
http_request_duration_seconds_bucket{le="0.005",app="notes-api",route="/api/notes",method="GET",tenant="globex"} 0

(2) FIXED   location = /metrics { return 404; }   (in both server blocks)
$ curl http://acme.abdur.169.58.246.108.nip.io:8141/metrics      (x3, status only)
  try 1: [HTTP 404]
  try 2: [HTTP 404]
  try 3: [HTTP 404]
$ curl http://127.0.0.1:3140/metrics | grep -c http_requests_total
14
```

From acme's own address anyone can read the **list of every other tenant's slug**
(the full dump in run 1 also showed `initech`, provisioned a minute earlier), how
much traffic each has, which features they use (globex has a custom domain — the
`/api/domains/:domain/verify` series) and their error rates and latency. That is
a cross-tenant information leak of exactly the "log line leaking across tenants"
kind, just through metrics instead of logs, and it exists because two correct
decisions — per-tenant labels (B3) and one shared instance (C4) — combine badly.

The fix is at the edge that defines tenant hostnames: nginx refuses `/metrics` on
both server blocks, while Prometheus keeps scraping the app **directly on
127.0.0.1:3140**, which never passes through a tenant-facing hostname — the
count of 14 series proves monitoring still works. Defence in depth would also
have the app refuse `/metrics` when a tenant header or custom domain is present.
Run 1 of this demo hit the same reload window as 62.3 (its "fixed" half returned
the whole metrics page); run 2 is shown.

**Other candidates I checked and did not find:** every notes/search/stats query
filters `tenant_id`; `GET /api/notes/:id` has the tenant in the `WHERE`, not in
an `if` after the fetch (B5's PR #1 removed it on purpose and the PR pipeline
caught it); C3's attachment keys are checked against the tenant before signing;
the tenant slug cache maps slug → id and tenants are never deleted; the custom
domain lookup is deliberately uncached.

<!-- status: DONE -->

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

**Note:** when this scenario began the cost figures on that page were
`Access denied` for this IAM user; access to billing information was enabled on
2026-09-14 (see constraints above), so the final billing screenshot can show real
numbers. Because the account is shared, those numbers will include other
students' spend — the cleanup is proven by the resource listings, and the
billing page is compared against `evidence/c0-billing-mtd.png` from before any
billable resource of mine existed.

<!-- local cleanup, not AWS: AWS CLI v2.36.44 was installed on the laptop for C2-C5
     because CloudShell refused to start ("account verification is in progress").
     Remove at the end:  rm -rf ~/aws-cli ~/.aws /opt/homebrew/bin/aws /opt/homebrew/bin/aws_completer -->

**Result: every resource I created is gone, verified by the brief's four
listings and by a name search across every service I used.** Script
[`c5-task63-cleanup.sh`](c5-task63-cleanup.sh), transcript
`evidence/c5-task63-cleanup.txt` (2026-09-15, 22:04:54 → 22:10:58 +06).
Billing screenshot: `evidence/c5-task63-billing.png`.

#### Inventory first, because the account is shared

Before deleting anything, a read-only inventory listed every resource in the
services I had used. It found two things that are **not mine** and must survive:
another student's S3 bucket `ashik-notes-attachments-750069566598`, and the
account's GitHub OIDC provider (created by another student on 2026-09-14; my
role only referenced it — task 53). The script therefore refuses to touch any
name that does not start with `abdur` (`mine()` stops the run), and it deletes
by exact name, never by listing-and-deleting everything.

#### Order — nothing deleted while something still depends on it

| # | Deleted | Why this position | Result |
| --- | --- | --- | --- |
| 1 | scaling policy `abdur-notes-cpu50`, scalable target | otherwise autoscaling could start tasks again; target tracking removes its two alarms with the policy | `alarms left: 0` |
| 2 | service `abdur-notes-svc` (desired 0, `--force`) | tasks hold ENIs in the security groups and targets in the TG | `INACTIVE`, `running tasks left: 0` |
| 3 | ALB `abdur-notes-alb` (listener with it), target group `abdur-notes-tg` | a TG cannot be deleted while a listener uses it | deleted |
| 4 | RDS `abdur-notes-db` — `--skip-final-snapshot --delete-automated-backups` | a retained snapshot or backup would keep billing; the RDS-managed master secret is deleted with the instance | deleted in 1 m 36 s, `secrets left: 0` |
| 5 | task definitions `abdur-notes-api:1-4` — deregister, then delete | deregistered revisions still exist; `delete-task-definitions` removes them | `DELETE_IN_PROGRESS` (completes asynchronously) |
| 6 | cluster `abdur-exam-cluster` | empty now; Container Insights (task 52) goes with it | `INACTIVE` |
| 7 | security groups db → app → alb | only after zero ENIs remain, and in reverse order of the rules that reference them (db-sg references app-sg, app-sg references alb-sg) | all three deleted |
| 8 | ECR `abdur-notes-api` `--force` | with every image (`v1.0.69`, `v1.0.91`, `v1.0.96`, `v1.0.100` and their per-platform manifests) | deleted |
| 9 | S3 `abdur-notes-750069566598` — objects, then bucket | a bucket must be empty; the last three objects from the C3 runs were removed | deleted |
| 10 | log group `/ecs/abdur-notes-api` | log storage bills per GB-month | deleted |
| 11 | roles `abdur-github-actions-ecs-deploy`, `abdur-ecs-task-role`, `abdur-ecs-task-execution-role` | inline policies deleted and the AWS-managed `AmazonECSTaskExecutionRolePolicy` detached first — a role with policies cannot be deleted | deleted |
| 12 | user `abdur-exam-deployer`, policy `abdur-exam-deployer-policy` | the policy detached first; its access key had already been deleted after task 47 | deleted |

Two things created earlier had already been removed at the time: the CloudFront
Origin Access Control from the refused distribution (task 57, deleted
immediately), and the CloudShell environment (Constraints §4).

#### The brief's checks

```
$ aws ecs list-clusters
{ "clusterArns": [] }
$ aws elbv2 describe-load-balancers
{ "LoadBalancers": [] }
$ aws s3 ls
2026-09-15 22:02:17 ashik-notes-attachments-750069566598
$ aws ec2 describe-instances --query 'Reservations[].Instances[?State.Name!=`terminated`].InstanceId'
[]
```

The one bucket listed is **another student's**, created at 22:02 — two minutes
before my cleanup began, long after mine existed — and is deliberately left
alone. I never created EC2 instances. In a shared account "nothing left" has to
mean "nothing of mine left", so the script also searched every service I used
for anything named `abdur`:

```
ECS clusters / task definitions / load balancers / target groups / RDS / RDS secret /
security groups / ECR / S3 / log groups / IAM roles / IAM users / IAM policies / alarms
→ all empty
```

#### Billing

`evidence/c5-task63-billing.png`, taken 2026-09-15 22:59 (+06), 49 minutes
after the cleanup finished, with the exam token alongside:

| | 2026-09-14 (`c0-billing-mtd.png`) | 2026-09-15, after cleanup |
| --- | --- | --- |
| Month-to-date | $10.61 | **$17.98** |
| Forecast for the month | data unavailable | $44.05 |
| Highest-cost service | — | Elastic Container Service, $7.73 MTD |
| Active services / regions | — | 14 services, 17 regions |

Reading it honestly:

- **These are account-wide figures.** The $7.37 rise between the two
  screenshots covers every student's resources for about a day and a half —
  including another student's ECS service that the baseline found running before
  I started — so it cannot be read as my spend. The ECS figure in particular is
  every Fargate task in the account this month.
- **It cannot be split by owner from here.** Every resource of mine carried the
  `exam-token` tag, but a tag only appears in billing once it is activated as a
  *cost allocation tag*, which is a billing-administrator setting and applies
  only to usage after activation.
- **AWS billing lags by up to a day**, so the final hours of my ALB, tasks and
  RDS will still be added after this screenshot.

My own estimate (list prices, below) is **about $1.6–2.0**. The proof that
nothing of mine keeps costing is the listings above, not the bill.

Estimated cost of what I ran (list prices, eu-north-1): RDS `db.t3.micro` about
**$0.022/h** from 2026-09-14 ~23:30 to 2026-09-15 22:08 (~22.5 h ≈ $0.50 incl.
storage), ALB about **$0.025/h + LCU** from 01:40 to 22:07 (~20.5 h ≈ $0.55),
two 0.25 vCPU / 0.5 GB Fargate tasks about **$0.012/h each** (~20.5 h ≈ $0.50,
plus the short-lived extra tasks in tasks 52 and 54), Container Insights for
~20 h, a few cents of ECR, S3, Secrets Manager and CloudWatch Logs — **roughly
$1.6–2.0 in total**.

#### What still refers to AWS, and why it is harmless

- The `deploy-ecs` job in `.github/workflows/deploy.yml` now has no role to
  assume; any push to `main` without `[skip ci]` would fail at its first step.
  It is left in place as the task 53 deliverable; every commit after the cleanup
  uses `[skip ci]`.
- The Scenario B/C4 deployment on the VPS does not use AWS at all.
- Locally: the AWS CLI installed for C2–C5 (233 MB in `~/aws-cli`), its
  `aws login` session cache in `~/.aws`, and `hey` were removed from the laptop on
  2026-09-15 after the last evidence was committed; `command -v aws` and
  `command -v hey` now find nothing.

<!-- status: DONE -->
