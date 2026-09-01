# Scenario C — Answers

**Exam token:** `REPLACE_WITH_EXAM_TOKEN`

> **Status: not started.** The copy of the brief I worked from was truncated
> mid-sentence at the cost warning ("use free tier. `t3.micro` o…"), so the
> individual task numbers and requirements for this scenario are not yet
> transcribed here. Everything below is what the section header and the
> cross-references from Scenario B establish, plus the pieces already built for
> it. See [`../INCOMPLETE.md`](../INCOMPLETE.md).

Section: **AWS and Multi-Tenancy — 94 marks**, covering sessions 6–9.
Constraint stated in the brief: stay in the free tier, `t3.micro`.

## What is already in place for this scenario

**OIDC instead of static credentials.** Scenario B's `deploy.yml` already
requests `id-token: write` and carries the commented
`aws-actions/configure-aws-credentials@v4` block. No
`AWS_SECRET_ACCESS_KEY` or static access key exists anywhere in this repo —
`grep -r` over `.github/` confirms it. The trust policy on the role must pin
both the repository and the branch:

```json
{
  "Condition": {
    "StringEquals": {
      "token.actions.githubusercontent.com:aud": "sts.amazonaws.com"
    },
    "StringLike": {
      "token.actions.githubusercontent.com:sub": "repo:<owner>/<repo>:ref:refs/heads/main"
    }
  }
}
```

Without the `sub` condition, **any** GitHub repository in the world can assume
the role — the single most common mistake in GitHub↔AWS OIDC setups.

**Security groups.** Port 22 must not be open to `0.0.0.0/0` — the brief makes
that an instant zero for the task. Plan: SSH restricted to my own `/32`, or no
inbound SSH at all and access via SSM Session Manager, which needs no inbound
rule whatsoever.

**Multi-tenancy.** The Notes API in `scenario-b/app` is already multi-tenant
(`X-Tenant` header, `tenant_id` in every `WHERE`, per-tenant metrics labels)
and Panel H already demonstrates one tenant degrading the service for others.

## To do

1. Paste the remainder of the Scenario C brief into this file's task list.
2. Work through the tasks.

<!--
Fill in per task, in the same style as scenarios A and B:

## Task NN — <name>

<what was asked>

**What I did:** ...
**Evidence:** evidence/c-taskNN-*.png
**Why it works / what I would do differently:** ...
-->
