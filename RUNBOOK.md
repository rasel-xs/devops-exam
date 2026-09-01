# RUNBOOK — the order to actually execute this

Everything in this repo is written and committed but **nothing has been run on
real infrastructure yet**. This is the order that minimises rework, because
several later tasks depend on artefacts produced by earlier ones.

## 0. Before anything else (5 min)

```bash
# On the VPS:
export EXAM_TOKEN="$(whoami)-$(hostname)-$(date +%s)-$(head -c4 /dev/urandom | xxd -p)"
echo "$EXAM_TOKEN" | tee ~/exam_token.txt
echo "export EXAM_TOKEN=\"$EXAM_TOKEN\"" >> ~/.bashrc
```

Then, in the repo, substitute it everywhere:

```bash
grep -rl REPLACE_WITH_EXAM_TOKEN . | xargs sed -i '' "s/REPLACE_WITH_EXAM_TOKEN/$EXAM_TOKEN/g"
grep -rl REPLACE_WITH_VPS_IP     . | xargs sed -i '' "s/REPLACE_WITH_VPS_IP/<your-ip>/g"
grep -rl REPLACE_WITH_GH_USER    . | xargs sed -i '' "s/REPLACE_WITH_GH_USER/<your-gh-user>/g"
git commit -am "Substitute exam token, server IP and registry owner"
```

(On Linux, `sed -i` without the `''`.)

**Screenshot helper** — put this in `~/.bashrc` and run `tok` before every
capture:

```bash
tok() { echo "$EXAM_TOKEN | $(date)"; }
```

## 1. Scenario A (needs only the VPS)

> **Shared server.** This box also hosts `ashik` and `badhon`. Unprefixed
> `alice`/`bob`/`carol`/`dan`, the groups `devs`/`ops`/`auditor` and `/srv/app`
> already exist and are **not mine**. Everything below is namespaced `abdur`.
> `setup-users.sh` refuses to run if an unprefixed name creeps back in.

**My allocation:** users/groups `abdur_*`, tree `/srv/abdur/app`, units
`abdur-myapp*`, ports 3100/3101/3102, nginx 8110, A2 mystery ports 8180/8181,
log `/var/log/abdur-healthcheck.log`, sudoers `/etc/sudoers.d/abdur-myapp`.

```bash
# A1 -- users, groups, ACLs, sudoers
sudo bash scenario-a/configs/setup-users.sh
tok; sudo -E bash scenario-a/configs/verify-a1.sh | tee scenario-a/evidence/a1-proof-table.txt

# A4 -- app + services (do this before A3: checks.conf points at these ports)
sudo mkdir -p /srv/abdur/app/src
sudo cp scenario-a/app/server.js /srv/abdur/app/src/
sudo cp scenario-a/configs/myapp.service          /etc/systemd/system/abdur-myapp.service
sudo cp scenario-a/configs/myapp@.service         /etc/systemd/system/abdur-myapp@.service
sudo cp scenario-a/configs/myapp-watchdog.service /etc/systemd/system/abdur-myapp-watchdog.service
sudo cp scenario-a/configs/myapp-watchdog.timer   /etc/systemd/system/abdur-myapp-watchdog.timer
sudo install -m755 scenario-a/configs/myapp-watchdog.sh /usr/local/bin/abdur-myapp-watchdog.sh
sudo systemctl daemon-reload
sudo systemctl enable --now abdur-myapp abdur-myapp@3101 abdur-myapp@3102

# A3 -- healthcheck + cron
sudo install -m755 scenario-a/configs/healthcheck.sh /usr/local/bin/abdur-healthcheck.sh
sudo mkdir -p /etc/abdur-healthcheck
sudo cp scenario-a/configs/checks.conf /etc/abdur-healthcheck/
sudo touch /var/log/abdur-healthcheck.log && sudo chmod 640 /var/log/abdur-healthcheck.log
# APPEND to root's crontab -- never `crontab <file>`, that would wipe ashik's entries
sudo crontab -l 2>/dev/null | cat - scenario-a/configs/crontab-entry.txt | sudo crontab -

# A5 -- nginx (install if absent; it is shared, so only ADD my conf)
sudo apt-get update && sudo apt-get install -y nginx
sudo cp scenario-a/configs/nginx-myapp.conf /etc/nginx/sites-available/abdur-myapp
sudo ln -sf /etc/nginx/sites-available/abdur-myapp /etc/nginx/sites-enabled/abdur-myapp
# do NOT remove sites-enabled/default -- not mine
sudo nginx -t && sudo systemctl reload nginx
tok; bash scenario-a/configs/a5-tests.sh | tee scenario-a/evidence/a5-tests.txt

# A2 -- LAST in scenario A: it deliberately occupies port 8180
```

## 2. Scenario B, local first (Docker on the Mac)

Faster to iterate on than the VPS, and B1–B3 need no server.

```bash
cd scenario-b
docker build -f docker/Dockerfile.naive -t notes-api:naive app/   # task 22 comparison
docker build -f docker/Dockerfile       -t notes-api:multi app/
docker images | grep notes-api

# task 26 part 1 -- the failure, on a FRESH volume
docker compose -f docker/docker-compose.broken-depends.yml down -v
docker compose -f docker/docker-compose.broken-depends.yml up      # screenshot the crash

# the working stack
docker compose -f docker/docker-compose.yml up -d --build
docker compose -f docker/docker-compose.yml exec app node db/seed.js
open http://localhost:9090/targets   # UP
open http://localhost:3001           # Grafana, admin/admin

./app/loadtest.sh http://localhost:3000 300     # take the Grafana screenshots DURING this
bash docker/drills/run-drills.sh | tee evidence/b2-drills.txt
```

## 3. GitHub

Push, open a PR that fails, fix it, merge. Configure the `production`
environment with a required reviewer **before** the first merge to main, or the
approval-gate screenshot cannot be taken.

## 4. Swarm on the VPS

Needs the image in GHCR, so it comes after the deploy pipeline has pushed once.

## 5. Scenario C

Paste the rest of the brief first.

---

## Fill-in checklist

Every `<<FILL: ...>>` in the two ANSWERS.md files is a number that must come
from a real run:

```bash
grep -rn "<<FILL" scenario-*/ANSWERS.md | wc -l     # count remaining
grep -rn "REPLACE_WITH" . --include='*.md' --include='*.yml' --include='*.conf' --include='*.service'
```
