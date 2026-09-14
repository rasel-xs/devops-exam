# Scenario C — what IAM user `rasel` could reach, before anything was created

`root-vmi3536696-1788282556-1536d427` — 2026-09-12

Account `Arraytics_aws` / **750069566598**. No root access; I was given this IAM
user. Before creating anything I needed to know which Scenario C tasks were even
possible, and an IAM user is often not allowed to write IAM or see billing.

## Method

The AWS CLI was not installed on my laptop (low disk space), so instead of
calling each API I opened each service's console page and recorded whether it
loaded or showed a permissions error. This is weaker than an API probe — a page
can load while a write on it is still denied — so write permission was then
confirmed task by task (IAM: the policy and user in task 47 were created
successfully; ECS: the cluster was created with a tag despite the account's
*Resource Tagging Authorization* setting).

The screenshots were shared during the working session and are summarised here;
they were not saved into this directory.

## Result

| Console page | Region shown | Loaded? | What it showed | Needed for |
| --- | --- | --- | --- | --- |
| IAM → Users | Global | **yes** | 9 users, including an existing `exam-deployer` | 47, 48 |
| ECR → Repositories | eu-north-1 | **yes** | new-console landing page | 49 |
| ECS → Clusters | eu-north-1 | **yes** | 0 clusters | 50–54 |
| EC2 → Load balancers | eu-north-1 | **yes** | 0 load balancers | 51 |
| CloudWatch → Log groups | eu-north-1 | **yes** | 0 log groups | 50 |
| S3 → Buckets | all regions | **yes** | 0 buckets | 55–58 |
| Billing and Cost Management | Global | **partly** | page loads; month-to-date, forecast and last-month cost all **Access denied**; Budgets widget visible reading **1 over budget** | 63 |

## What that meant

- Everything C2 and C3 need was reachable.
- `exam-deployer` already existed and belonged to someone else, so every resource
  I create is prefixed `abdur-` (see ANSWERS.md, *Constraints*).
- The billing denial was not an IAM policy — this user appears to hold
  `AdministratorAccess` — but the separate, root-only switch that allows IAM
  users to see billing data. It was switched on by 2026-09-14, when the same page
  showed month-to-date **$10.61** (`c0-billing-mtd.png`).
