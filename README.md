# DevOps Practical Exam

**Name:** Abdur Rahim (GitHub: rasel-xs)
**Exam token:** `root-vmi3536696-1788282556-1536d427`
**Server IP:** `169.58.246.108`

> Generate the token on the VPS *before anything else*:
>
> ```bash
> export EXAM_TOKEN="$(whoami)-$(hostname)-$(date +%s)-$(head -c4 /dev/urandom | xxd -p)"
> echo "$EXAM_TOKEN" | tee ~/exam_token.txt
> echo "export EXAM_TOKEN=\"$EXAM_TOKEN\"" >> ~/.bashrc
> ```
>
> Then replace every `root-vmi3536696-1788282556-1536d427` in this repo:
>
> ```bash
> grep -rl root-vmi3536696-1788282556-1536d427 . | xargs sed -i '' "s/root-vmi3536696-1788282556-1536d427/$EXAM_TOKEN/g"   # macOS
> grep -rl root-vmi3536696-1788282556-1536d427 . | xargs sed -i    "s/root-vmi3536696-1788282556-1536d427/$EXAM_TOKEN/g"   # Linux
> ```

## Hosted / live links

| What | Where |
| --- | --- |
| App behind nginx (Scenario A) | http://169.58.246.108:8110/ |
| Grafana dashboard (Scenario B) | http://169.58.246.108:3130/ (`exam-root-vmi3536696-1788282556-1536d427`) |
| Prometheus | http://169.58.246.108:9190/ |
| Container registry | ghcr.io/rasel-xs/notes-api |
| Scenario C app | REPLACE_WITH_AWS_URL |

## Repository map

```
README.md            this file
AI_PROMPTS.md        AI prompt log (bonus marks)
TIMELINE.md          work diary
INCOMPLETE.md        what is NOT finished, and how far I got

scenario-a/          the inherited server: users, ACL, sudo, ports, bash, systemd, nginx
  ANSWERS.md
  app/               zero-dependency Node app (/, /healthz, /slow, /crash, /hang, /whoami)
  configs/           setup scripts, healthcheck.sh, systemd units, nginx conf, sudoers
  evidence/          screenshots, named a<task>-<what>.png

scenario-b/          containerize, ship, observe
  ANSWERS.md
  app/               multi-tenant Notes API + Prometheus instrumentation + tests + seeder
  docker/            Dockerfile, Dockerfile.naive, compose files, prometheus.yml, stack.yml
  grafana/           dashboard.json (9 panels) + datasource provisioning
  evidence/

scenario-c/          AWS and multi-tenancy
  ANSWERS.md
  evidence/

.github/workflows/   pr.yml (PR pipeline), deploy.yml (main branch + approval gate)
```

## Screenshot convention

Every terminal screenshot is preceded, in the same terminal, by:

```bash
echo "$EXAM_TOKEN | $(date)"
```

Browser screenshots (Grafana, GitHub Actions, AWS console) carry the token in the
dashboard title / workflow file comment, or in a terminal window beside the browser.

## Running things

| Task | Command |
| --- | --- |
| Scenario A app locally | `PORT=3000 node scenario-a/app/server.js` |
| Scenario B stack | `docker compose -f scenario-b/docker/docker-compose.yml up -d` |
| Seed the DB | `docker compose -f scenario-b/docker/docker-compose.yml exec app npm run seed` |
| Load test | `scenario-b/app/loadtest.sh` |
| Unit tests | `cd scenario-b/app && npm test` |
