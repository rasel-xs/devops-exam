# Scenario C — account baseline, recorded BEFORE creating anything

`root-vmi3536696-1788282556-1536d427` — 2026-09-12
Account `Arraytics_aws` / **750069566598**, IAM user `rasel`, no root access.

Taken from **EC2 → AWS Global View** and **Resource Groups → Tag Editor**
(All regions, all supported resource types), because the Billing console denies
this user every cost figure and I needed to know what the account was already
paying for before adding to it.

## Why this file exists

Two reasons, both about being able to prove something later:

1. The Budgets widget read **"1 over budget"** before I had created a single
   resource. If I do not record the state I inherited, I cannot later show that
   the overspend was not mine.
2. Task 63's cleanup commands are **per-region**. My region will be empty at the
   end, but the account will still hold other students' resources. Without this
   baseline, "there is still an ECS cluster in this account" looks like I failed
   to clean up.

## What was already there

```
Enabled regions      17
Instances            0 in 0 regions
Volumes              0 in 0 regions
RDS clusters         0 in 0 regions
RDS DB instances     0 in 0 regions
S3 buckets           0 in 0 regions
NAT gateways         0 in 0 regions
Auto scaling groups  0 in 0 regions

ECS clusters         2 in 2 regions     <-- not mine
ECS services         1 in 1 regions     <-- not mine, and costing money
Elastic IPs          2 in 1 regions     <-- not mine, and costing money
Network interfaces   5 in 1 regions

Networking (total)   381                <-- default VPC furniture, free
Security             34
```

Identified by name in the Tag Editor listing:

| Resource | Type | Region | Whose |
| --- | --- | --- | --- |
| `badhon-devops-exam-cluster` | ECS cluster | `ap-northeast-3` | another student (`badhon`) |
| `ECS-Console-V2-Service-fc-no…` | CloudFormation stack | `us-east-1` | another student (the `fc-exam-deployer` user) |

## Reading it

**The 381 "networking" resources are free.** They are the default VPC, subnets,
route tables, internet gateways, DHCP option sets, network ACLs and security
groups that AWS creates in every enabled region — 17 regions × roughly 22
objects. None of them is billed. It looks alarming and means nothing.

**The billed items are the ECS service and the two Elastic IPs**, and neither is
mine. There are no EC2 instances, no RDS, no S3, no NAT gateways and no volumes,
so nothing else in the account can be generating charges. A single small Fargate
service plus two Elastic IPs is on the order of $0.50–1.00 per day, which is
consistent with a $5 budget being exceeded within a week.

**An unattached Elastic IP is charged for precisely because it is unattached** —
AWS bills idle addresses to discourage hoarding a scarce resource. With
`Instances: 0` and `NAT gateways: 0` in the account, those two addresses have
almost nothing they could be attached to, so they are very likely pure waste.
Whoever administers this account should be told.

**`eu-north-1` holds nothing.** That confirms the region choice: the other two
students are in `ap-northeast-3` and `us-east-1`, so nothing I create can
collide with or be mistaken for theirs.

## Noise in the Tag Editor output, explained

The scan returned a red `ForbiddenException` banner:

```
This account does not have access to the Cloud9 service - AWS::Cloud9::Environment (17 regions)
Access denied to Amazon Fraud Detector - AWS::FraudDetector::* (1-2 regions each)
```

These are not permission problems with my user. Tag Editor enumerates *every*
taggable resource type; Cloud9 and Fraud Detector are not enabled on this
account, so the API refuses the enumeration for those types. Every other type
returned normally. Worth stating because a red banner in a screenshot invites
the question.
