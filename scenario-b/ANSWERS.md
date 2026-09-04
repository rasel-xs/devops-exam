# Scenario B — Answers

**Exam token:** `root-vmi3536696-1788282556-1536d427`
**Server:** `169.58.246.108` — Ubuntu 24.04.4, Docker 29.7.2, Compose v5.5.0

> **Shared machine.** This VPS also hosts other students, and one of them
> already runs containers named `notes-api` / `notes-db` with a
> `docker_notes-db-data` volume. Everything here is namespaced: compose project
> `abdur-notes`, image `abdur/notes-api`, host ports 3120 (app), 3130 (Grafana),
> 9190 (Prometheus), 5433 (Postgres), 3140 (Swarm), stack `abdur_notes`.
>
> Every number in this document is measured. Where a measurement came out
> uninteresting, or contradicted what I predicted, it is reported as it came out.

**Library note:** the brief names `prom-client` for Node and that is what I
used. `npm install` prints a deprecation notice saying it has been renamed to
`@prometheus-io/client`; the API is identical (it is a rename, not a rewrite),
but the successor restarted at 0.16.x so I stayed on the version the brief
specifies rather than taking a versioning discontinuity into an exam.

---

## B1 — The image

### Task 21 — Multi-stage build

[`docker/Dockerfile`](docker/Dockerfile). Two stages: `deps` on `node:20-bookworm`
runs `npm ci --omit=dev`, `runtime` on `node:20-alpine` copies only
`node_modules`, `src`, `db` and `package.json`.

- **No build tools** — the compiler, npm cache and every devDependency stay in
  the `deps` stage, which is never part of the final image. Nothing is
  "deleted"; it is never copied.

  **My own test caught this claim being false the first time.** Probing the
  image for eight tools rather than assuming produced:

  ```
    absent  (good): gcc, g++, make, python3, git, curl, vim
    PRESENT (bad):  npm
  ```

  npm was not installed by me — `node:20-alpine` ships it. A package manager in
  a runtime image is a real risk rather than untidiness: an attacker with code
  execution gets a ready-made way to fetch and run more code. Nothing here
  needs it, since `node_modules` arrives prebuilt from the `deps` stage, so the
  runtime stage now removes npm, npx and yarn before `USER node`. After that:

  ```
    absent : npm
    absent : npx
    absent : yarn
    PRESENT: apk       <- Alpine's own package manager, deliberately kept
    PRESENT: node      <- obviously required
  ```

  `apk` is still there and I am not going to pretend otherwise. Removing it
  fights the base image; the right answer at that point is a distroless base
  (`gcr.io/distroless/nodejs20`) that never had a package manager or a shell.
  I did not switch because it also removes `wget`, which my `HEALTHCHECK` uses,
  and that would need a compiled probe or a `HEALTHCHECK NONE` plus an
  orchestrator-level probe instead. Documented trade, not an oversight.
- **Non-root** — `USER node`, the uid 1000 account that `node:alpine` already
  ships. This is PID 1 in the container, so a container escape starts from an
  unprivileged uid.

  ```
  $ docker run --rm abdur/notes-api:multi whoami  ->  node
  $ docker run --rm abdur/notes-api:multi id      ->  uid=1000(node) gid=1000(node) groups=1000(node)
  ```

- **HEALTHCHECK** — `wget --spider http://127.0.0.1:3000/healthz` every 10s
  with `--start-period=15s`. It hits `/healthz` (liveness, no DB) rather than
  `/readyz` deliberately: if the healthcheck touched the database, a database
  blip would make the orchestrator kill every healthy app container as well and
  turn a database incident into a total outage.

  ```
  $ docker ps
  NAMES      STATUS
  abdur-hc   Up 6 seconds (healthy)

  $ docker inspect --format='{{json .State.Health}}' abdur-hc | jq
  { "Status": "healthy", "FailingStreak": 0,
    "Log": [ { "ExitCode": 0, ... } ] }
  ```

  **Healthy in 6 seconds, with no database attached at all.** That is the point
  of pointing the healthcheck at `/healthz` and not `/readyz`: liveness must
  not depend on the database, or a database blip makes the orchestrator kill
  every healthy app container too and turns a database incident into a total
  outage.

One detail worth stating: `CMD ["node", "src/server.js"]` is the exec form. The
shell form would run `/bin/sh -c node ...`, putting sh at PID 1, and sh does not
forward signals — the app would never receive SIGTERM and every rolling update
would hard-kill it after the grace period. That is a direct cause of dropped
requests in task 37.

### Task 22 — Size

| Image | `docker images` | `image inspect .Size` |
| --- | --- | --- |
| `abdur/notes-api:naive` | **1.66 GB** | 399 MB |
| `abdur/notes-api:multi` | **207 MB** | 48 MB |
| Reduction | **87.5 %** | **87.9 %** |

Comfortably past the 60 % the brief requires, by either measure.

**The two columns disagree and I checked why rather than picking the flattering
one.** `docker images` reports the uncompressed on-disk size of everything in
the manifest list; `docker image inspect .Size` reports the packed size of a
single platform. The absolute numbers differ by roughly 4x, the *ratio* agrees
to within half a percent, and the ratio is what the question asks about. Worth
knowing because "how big is my image" has at least three defensible answers —
on-disk, compressed-in-registry, and per-platform — and people quote whichever
suits them.

**What was removed, and what that cost:**

| Removed | Saved | What I gave up |
| --- | --- | --- |
| Debian base → Alpine (musl) | ~300 MB | glibc. Native modules must have musl builds or be compiled in-stage; some prebuilt binaries simply will not run. This is the only change here with real risk. |
| `build-essential`, `python3`, `git` | ~400 MB | Cannot rebuild native modules inside the container. Correct — a runtime image should not be able to compile. |
| devDependencies (`--omit=dev`) | **0 bytes** | Nothing, because there was nothing to give up — see below. |
| `npm cache clean --force` | ~50 MB | Nothing. It is a download cache for a machine that will never install again. |
| npm, npx, yarn (removed explicitly) | see note | Cannot install anything at runtime — which is the entire point. Note this removal does **not** shrink the image: see task 25. |
| `vim`, `curl` | ~30 MB | Debugging inside the container is harder — no shell tooling to poke around with. Mitigation is `docker debug` / an ephemeral sidecar sharing the namespace, not shipping an editor to production. |

**`--omit=dev` saved nothing here, and I am not going to pretend otherwise.**
`package.json` has `"devDependencies": {}` — the app's only dependencies are
`express`, `pg` and `prom-client`, all of which are runtime. The flag is still
correct to keep, because it is a *policy*: the day someone adds `jest` or
`eslint`, the production image will not grow, and nobody has to remember to
change the Dockerfile. But its measured contribution to this image's size is
zero, and a table that quoted a plausible-looking "~40 MB" there would have been
an invented number in the middle of a set of measured ones.

The honest trade: the small image is harder to debug in place. That is the right
trade — a runtime image that can compile code and edit files is also a much more
useful place for an attacker to land.

### Task 23 — Layer caching

Adding a comment to `src/server.js` and rebuilding:

| Build | Time |
| --- | --- |
| Cold (`--no-cache`) | **16.8 s** |
| Warm, no change at all | **2.2 s** |
| Warm, after a one-line source change | **3.6 s** |

**The first attempt at this measurement was wrong and I had to fix the method.**
It reported the source-change rebuild as *faster* than the no-change rebuild,
which is impossible. The cause was the default `--progress=auto`, which
collapses completed steps, so my filter was reading an incomplete step list and
the timings were dominated by noise. `--progress=plain` prints every step with
its `CACHED` marker and the numbers become sane.

**Which layers rebuilt, and why.** With no change, every step is `CACHED`
including `[deps 4/4] RUN npm ci`. After appending one comment to
`app/src/server.js`:

```
#13 CACHED   [deps 4/4] RUN npm ci --omit=dev && npm cache clean --force
#14 CACHED   [runtime 4/7] COPY --from=deps ... /build/node_modules
#16 CACHED   [runtime 5/7] COPY --chown=node:node package.json ./
#17          [runtime 6/7] COPY --chown=node:node src ./src        <- cache miss starts here
#18          [runtime 7/7] COPY --chown=node:node db ./db          <- and everything after
```

`npm ci` stays cached because `package.json` and the lockfile did not change.
The miss begins at `COPY src` and everything below it rebuilds, because
Docker's cache is a **chain** — one miss invalidates the remainder regardless
of whether those later layers would have produced identical output.

This is entirely because of copy order:

```dockerfile
COPY package.json package-lock.json* ./   # changes rarely
RUN npm ci --omit=dev                     # expensive -- stays cached
COPY src ./src                            # changes constantly
```

`Dockerfile.naive` does `COPY . .` *before* `npm install`, so any change to any
file invalidates the install layer and re-downloads every dependency. That is
the difference between the two times above. General rule: order layers from
least to most frequently changed.

### Task 24 — The biggest layer

```bash
docker history --no-trunc --format "{{.Size}}\t{{.CreatedBy}}" notes-api:multi
```

```
130MB   RUN addgroup -g 1000 node && adduser ... && apk add libstdc++ ...   <- the Node runtime, from the base image
 11.3MB COPY --from=deps --chown=node:node /build/node_modules ./node_modules
  9.11MB ADD alpine-minirootfs-3.23.4-x86_64.tar.gz /
  5.48MB RUN apk add --no-cache --virtual .build-deps-yarn curl gnupg tar ...
 32.8kB COPY --chown=node:node src ./src
 28.7kB RUN rm -rf /usr/local/lib/node_modules/npm ...
```

**Biggest layer: 130 MB — the Node.js runtime itself**, installed by the
`node:20-alpine` base image, not by anything I wrote. My own application code
is 32.8 kB and its dependencies 11.3 MB; the language runtime is over ten times
the size of everything I contributed.

**Could it be smaller?** Yes, in order of effort:

1. `npm ci --omit=dev` is already there. Beyond that, `npm dedupe`, and auditing
   what actually needs to ship — `express` pulls a long transitive tail.
2. Bundle with `esbuild`/`ncc` into a single file and ship no `node_modules` at
   all. Typically cuts it by more than half, at the cost of a build step and
   harder stack traces.
3. Use a distroless or `node:20-alpine`-slim base, or `node --experimental-sea`
   for a single executable.
4. **Since the biggest layer here is the base image, the honest answer is
   mostly "leave it alone".** That layer is shared by every image built from
   `node:20-alpine` on the host: it is pulled once and reused, so shrinking it
   would save far less real disk and bandwidth than its size suggests. The
   layers actually worth attacking are the ones unique to me, and they already
   total under 12 MB.

Note the `rm -rf npm` layer is **28.7 kB, not −130 MB**. Deleting files in a
later layer cannot shrink the image — see task 25, which is the same mechanism
seen from the other side.

The thing NOT to do is squash layers to make the number smaller. That destroys
cache sharing between images and makes pulls slower overall.

### Task 25 — No secrets in the image

Transcript: [`evidence/b1-session.txt`](evidence/b1-session.txt).

**"My scan found nothing" is not evidence.** A scan that finds nothing might
simply be broken — and mine was, twice. The first version counted `*.tar`
files, which Docker 25+ no longer produces (it writes OCI blobs under
`blobs/sha256/`), and it used `grep -I`, which **skips binary files** — so it
never looked inside the gzipped layer blobs at all, then cheerfully reported
"no secrets found".

So the test now runs against a **negative control** first:
[`docker/Dockerfile.leaky`](docker/Dockerfile.leaky) writes a known credential
and deletes it in a later layer, exactly the trap the brief describes.

```
>>> NEGATIVE CONTROL
    (the file is NOT in the running container:)
    ls: /app/.env: No such file or directory
    (but the bytes are still in an earlier layer:)
      layers extracted : 4
      MATCHES:
        l3/app/.env
            > DB_PASSWORD=hunter2-LEAKED-MARKER-9f3a
```

The scan recovers a secret that `rm` was supposed to have destroyed. Only now
does the result for the real image mean anything:

```
>>> THE REAL IMAGE, scanned exactly the same way:
  layers extracted : 10
  MATCHES (each needs triage -- a match is not automatically a leak):
    l7/opt/yarn-v1.22.22/lib/cli.js
        > secretAccessKey: env.AWS_SECRET_ACCESS_KEY || env.AWS_SECRET_KEY,
    l6/usr/local/lib/node_modules/npm/man/man7/config.7
        > key="-----BEGIN PRIVATE KEY-----\nXXXX\nXXXX\n-----END PRIVATE KEY-----"
    l6/.../npm/node_modules/@npmcli/config/lib/definitions/definitions.js
    l6/.../npm/docs/content/using-npm/config.md
    l6/.../npm/docs/output/using-npm/config.html
```

**Five matches, all false positives, and each one triaged by reading the
matching line** — which is why the scan prints it rather than just the
filename:

- yarn's `cli.js` reads the *name* of an environment variable; there is no
  value in the image.
- The four npm files are documentation showing the format of the `key` config
  option. The "key" is the literal string `XXXX`.

A scan that only printed filenames would have produced five alarming-looking
paths and no way to judge them.

### The part I did not expect: my own image proves the lesson

Those matches are in layers **l6 and l7** — npm's and yarn's files. But I
*removed* npm and yarn in the runtime stage, and verified it:

```
$ docker run --rm abdur/notes-api:multi sh -c 'command -v npm'
  absent
```

Both are true at once:

| Question | Answer |
| --- | --- |
| Can a process in the container run npm? | **No** — the whiteout hides it |
| Are npm's bytes still in the image? | **Yes** — intact in layer 6 |
| Did removing it shrink the image? | **No** — the `rm` layer is **28.7 kB**, not −130 MB |

So my own `rm -rf npm` is the exact same mistake as `RUN rm /app/.env`, just
with something harmless. It buys a real security property (no package manager
reachable at runtime) and **zero** of the properties people assume it buys.

**Why `rm` in a later layer does not help.** An image is an ordered stack of
immutable, content-addressed layers. Each instruction adds a layer containing
only its changes; earlier layers are never modified, because they are shared
between images and identified by their content hash. Deleting a file writes a
**whiteout** entry — a marker meaning "hide this path from here down". That
marker governs what a *running container* sees. Anyone holding the image can
ignore it entirely:

```bash
docker save leaky:v1 -o img.tar && tar -xf img.tar
# extract each layer blob and read the file straight out of the earlier layer
```

or read the layer blobs directly from the registry without even pulling.

**What actually works:**

1. **Never let it into the build context.** `.env` is in
   [`app/.dockerignore`](app/.dockerignore) (lines 7-8), so it cannot reach any
   layer. This is the fix I used.
2. **Build secrets** — `RUN --mount=type=secret,id=npmrc ...`. BuildKit mounts
   it for one command and it is never committed to a layer.
3. **Inject at runtime** — environment variables, a mounted file, or Swarm
   secrets in a tmpfs at `/run/secrets/`.

And if a secret has already been built into a pushed image, the only real
remediation is to **rotate the secret**. Deleting the tag does not un-publish
bytes someone may already hold.

## B2 — Compose, storage, debugging

### Task 26 — `depends_on` is not enough

Evidence: `evidence/b2-task26.txt`, generated by `docker/b2-task26.sh`.

**My prediction was wrong, and the real result is worse.** I expected the app to
die with `ECONNREFUSED`. It did not. On a fresh volume the broken stack came up
`Up (healthy)` and stayed that way. The reason is three design decisions
stacked on top of each other:

1. node-postgres `new Pool()` is **lazy** — it opens no socket until the first
   query, so an absent database costs nothing at construction time;
2. `app.listen()` never touches the database;
3. `/healthz` is a **liveness** probe and deliberately does not touch the
   database either (B1 task 21c).

So the container passed its healthcheck while being unable to serve a single
row. That is worse than a crash: a crash restarts and pages someone, a lying
healthcheck gets production traffic routed into it.

**Measuring it.** `/readyz` does query the database, so it is the honest
signal. Polling both probes every 0.5 s from `up -d`, on a volume destroyed by
`down -v` first:

| Stack | first `/healthz`=200 | first `/readyz`=200 | lying-healthy window |
|---|---|---|---|
| `docker-compose.broken-depends.yml` (`depends_on:` only) | 0.6 s | 3.6 s | **3.0 s** |
| `docker-compose.yml` (`condition: service_healthy`) | 1.2 s | 1.2 s | **0.0 s** |

For three seconds the broken stack answered `200` on `/healthz` and `503` on
`/readyz` on every single poll.

**Confirmed against the containers' own clocks**, not my stopwatch:

```
app-1       17:49:13.094  {"level":"info","msg":"listening","port":3000}
postgres-1  17:49:15.825  [1] LOG: database system is ready to accept connections
                                        gap = 2.73 s
```

**The initdb temporary-server trap, caught on camera.** The Postgres log says
"ready to accept connections" **twice**:

```
17:49:15.129  [41] LOG:  database system is ready to accept connections   <- temporary
17:49:15.365  [42] LOG:  shutting down
17:49:15.825  [1]  LOG:  database system is ready to accept connections   <- real
```

PID 41 is the throwaway server initdb runs to create the role and the database;
it is shut down and the real server (PID 1) takes over 0.7 s later. This is
exactly why the healthcheck is

```yaml
test: ["CMD-SHELL", "pg_isready -U notes -d notes -h 127.0.0.1"]
```

and not a bare `pg_isready`: `-h 127.0.0.1` forces TCP (the temporary server
listens only on a unix socket) and `-U notes -d notes` demands the real
credentials against the real database. A bare `pg_isready` would have opened
the gate against PID 41.

**The intermittency is the whole danger.** On a second run the volume is already
initialised, Postgres is ready in well under a second, and the broken file
"works". The bug passes on a laptop and fails on a cold deploy or in CI.

**The fix**, two independent layers:

```yaml
depends_on:
  postgres:
    condition: service_healthy
```

plus the healthcheck above, plus a 60 s retry loop in `db/migrate.js`. The
app-side retry is not redundant: Compose's `condition:` **does not exist in
Swarm** (B4 has no `depends_on` at all), and databases restart while
applications are running. An app that cannot survive its database going away
for ten seconds is broken regardless of what started it.

**Honest limits of this measurement.**

- The fixed stack's `t=0` is later in wall-clock than the broken stack's,
  because `up -d` itself blocked on `postgres Waiting -> Healthy` before the
  poll started. The `0.0 s` window is real; the two *total* times are not
  directly comparable.
- I expected `docker inspect .State.Health.Log` to show a failing check
  followed by a passing one. Both recorded entries are `exit=0`. With
  `interval: 3s`, initdb finished inside the first interval, so no failure was
  ever recorded. Compose still waited — the `Waiting`/`Healthy` lines prove it
  — but I cannot claim a fail-to-pass transition, so I do not.

### Task 27 — Volumes and persistence

Evidence: `evidence/b2-task27.txt`, generated by `docker/b2-task27.sh`. Row
counts come from `psql`, not from the API — the API could be serving a cache or
pointing at the wrong database, `psql` cannot.

| Step | `SELECT count(*) FROM notes` |
| --- | --- |
| seeded, plus 3 marker notes written through `POST /api/notes` | **50,003** |
| `docker compose down` → `up -d` | **50,003** — survived |
| `docker compose down -v` → `up -d` | **0** — destroyed |
| `bash docker/backup-restore.sh restore <dump>` | **50,003** — recovered |

The final check is not the count but the rows: `SELECT id, title FROM notes
WHERE title LIKE 'TASK27-%'` returns the three marker titles written before the
backup. Matching totals could be a coincidence; the markers cannot.

**What `-v` did.** `docker compose down` removes containers and networks and
leaves named volumes alone — that is why the data survived. `-v` additionally
removes the named volumes *declared in the compose file*, so `pgdata` — the
Postgres data directory itself — is deleted. `docker volume ls` proves it
either side:

```
after `down`      abdur-notes_pgdata
after `down -v`   (none)
```

The next `up` creates a brand new empty volume and Postgres initdbs into it.
There is no undo and no confirmation prompt. `down -v` is the most dangerous
routine Docker command there is, and it is one keystroke away from `down`.

Related trap: `-v` only removes volumes declared in the compose file. Anonymous
volumes created by the image survive, which is why a database sometimes appears
to keep old data even after `down -v`.

**Recovery** — [`docker/backup-restore.sh`](docker/backup-restore.sh):

```bash
bash docker/backup-restore.sh backup            # pg_dump | gzip -> ./backups/
docker compose down -v && docker compose up -d  # data destroyed
bash docker/backup-restore.sh restore backups/notes-<ts>.sql.gz
```

I used a **logical** dump (`pg_dump --clean --if-exists`) rather than tarring
the volume. A logical dump is portable across Postgres versions and
architectures and is consistent without stopping the server; `--clean
--if-exists` makes the restore idempotent instead of colliding with the tables
`migrate.js` has already created. A tar of `/var/lib/postgresql/data` is a
physical copy: it only restores into the same major version, and it is a torn,
possibly unstartable copy unless Postgres is stopped first or you use
`pg_basebackup`. Both are in the script, with that caveat in a comment.

**Two bugs this task found in my own work.**

1. `backup_volume()` had the volume name hardcoded as `docker_pgdata`, left over
   from a different project. Compose prefixes volume names with the project
   name, so the real name is `abdur-notes_pgdata`. The failure would have been
   **silent**: `docker run -v docker_pgdata:/data` does not error on an unknown
   name, it *creates a new empty volume*, so the backup would have run, written
   a tarball, and archived nothing. The name is now derived from the container:

   ```bash
   vol=$(docker inspect -f '{{range .Mounts}}{{if eq .Destination "/var/lib/postgresql/data"}}{{.Name}}{{end}}{{end}}' "$cid")
   ```

2. The first run of the whole task was **vacuous**: every `POST` returned
   `{"error":"unknown tenant: acme"}`, so all four counts were `0` and the
   summary looked like a clean pass. `resolveTenant` looks the slug up in the
   `tenants` table; `migrate.js` creates the schema but the rows come from
   `seed.js`, which had never been run. A backup of an empty database restoring
   an empty database proves nothing. The lesson is about tests, not about
   Docker: **a test whose fixture failed to load can still report success**, so
   the setup step now asserts on `count(*) FROM tenants` before proceeding, and
   seeds only in setup — re-seeding after the `down -v` would have restored the
   data from the seeder rather than from the backup and quietly faked the whole
   result.

### Task 28 — The debugging drill

Four failures, each caused deliberately and then diagnosed. Scripts:
`docker/drills/run-drills.sh`, `docker/drills/b2-task28-followup.sh`,
`docker/drills/b2-task28-followup2.sh`. Evidence: `evidence/b2-drills.txt`,
`evidence/b2-drills-followup.txt`, `evidence/b2-drills-followup2.txt`.

Every drill below is written as: symptom → the *one* command that settles it →
root cause → fix. Four of my initial explanations were wrong; each is recorded
with what actually happened, because a wrong hypothesis that survived a test is
worth more than a right one that was never tested.

---

#### 28a — container exits with code 137

**Symptom.** `docker ps -a` shows `Exited (137)`.

**Reading the number.** `137 = 128 + 9`. The 128 means "killed by a signal",
the 9 is `SIGKILL`. Compare `143 = 128 + 15 = SIGTERM`, which means something
asked it to stop politely.

**137 on its own proves nothing**, and that is the trap. Two controls:

| what I did | ExitCode | OOMKilled |
| --- | --- | --- |
| 50 MB limit, process allocates past it | 137 | **true** |
| `docker kill` | 137 | **false** |
| `docker stop` on a container with a handler | 0 | false |

**The command that settles it:**

```bash
docker inspect --format='{{.State.ExitCode}} {{.State.OOMKilled}}' <cid>
```

`.State.OOMKilled` is the only field that separates a kernel OOM kill from any
other `SIGKILL`.

**Fix.** Raise the limit, or lower the app's memory ceiling to fit inside it
(`NODE_OPTIONS=--max-old-space-size`), so the runtime GCs instead of the kernel
killing. A limit below what the runtime needs at rest is not a limit, it is a
timer.

**Wrong prediction 1 — `docker stop` gave 137, not 143.**
The test container ran `node -e 'setInterval(...)'` with no `SIGTERM` handler,
as PID 1. **The kernel does not apply default signal actions to PID 1.** With
no handler installed the signal is simply discarded; Docker's grace period
expired and `SIGKILL` followed. Proved by four variants, where the *time
`docker stop` took* is the tell:

| PID 1 | exit | `docker stop` took |
| --- | --- | --- |
| node, no handler | 137 | **6 s** (grace expired) |
| node, `process.on('SIGTERM')` | 0 | 1 s |
| tini (`--init`), node as its child | **143** | 1 s |
| `sh -c 'node …'` | 137 | 6 s |
| our real `server.js` | 0 | 1 s, and it logged `shutting down` |

The tini row is the proof of the mechanism: the *same* handler-less node exits
143 the moment it is no longer PID 1, because the default action applies again.

The `sh -c` row surprised me too: busybox `sh` **exec-replaces itself** when
given a single simple command, so node was PID 1 again. See 28a-note below.

**Wrong prediction 2 — the compose version "ignored the memory limit".**
`docker inspect` after a fixed `sleep 15` said `Status=running`, and I nearly
wrote that `deploy.resources` is not honoured outside Swarm. It is honoured
(`MemoryLimit=52428800`). Two hypotheses, both testable:

- *swap* — rejected: `MemorySwap=104857600` in both cases, and the host has
  `Swap: 0B`;
- *page residency* — confirmed: `Buffer.alloc(n)` returns zeroed memory that
  can be a fresh anonymous mapping which is never written, so it costs address
  space and not resident pages, and a cgroup charges **resident** pages.

| code | time to OOM |
| --- | --- |
| `Buffer.alloc(10MB)` | **87 s** |
| `Buffer.alloc(10MB).fill(1)` | **< 1 s** |

Both end at `137 / OOMKilled=true`. The difference is speed, not outcome — so
the real bug was **my fixed `sleep 15`**, which was shorter than the failure it
was waiting for. A hard-coded sleep in a test can invert the test's conclusion.
`run-drills.sh` now waits on `docker wait` instead.

**28a-note, and it applies to our own stack.** Our compose runs
`command: ["sh", "-c", "node db/migrate.js && node src/server.js"]`. That is a
*compound* command, so I expected `sh` to remain PID 1 and swallow `SIGTERM`,
breaking graceful shutdown — which would matter in B4, where rolling updates
stop tasks with `SIGTERM`. Checked instead of assumed:

```
$ docker compose exec app ps -o pid,args
PID   COMMAND
    1 node src/server.js
```

`sh` exec's the **last** command of a list rather than forking it, so node ends
up as PID 1 anyway; `docker compose stop` returned in 1 s with
`{"msg":"shutting down","signal":"SIGTERM"}` in the log. So the stack is
correct — but by an optimisation in `ash`, not by design. Append anything after
`node src/server.js` and `sh` would stay at PID 1 and the shutdown handler
would never run. The robust form is `exec node src/server.js` in an entrypoint.

---

#### 28b — the app cannot reach the DB by service name

**Symptom.** `getaddrinfo ENOTFOUND postgres` from the app; the database is
plainly running.

**The command that settles it** — the same lookup from three networks, using
node's `dns.lookup` (i.e. `getaddrinfo`, the exact path the app uses) rather
than `getent`, which is a busybox applet that may not exist and would produce a
"does not resolve" that really means "no such binary":

```bash
docker run --rm --network <net> $IMG node -e "require('dns').lookup('postgres', ...)"
```

| network | result |
| --- | --- |
| `abdur-notes_default` (postgres's own) | `postgres -> 172.21.0.2` |
| the legacy default `bridge` | `ENOTFOUND` |
| a different user-defined bridge | `EAI_AGAIN` |

**Root cause.** Docker's embedded DNS resolver — `nameserver 127.0.0.11`, which
is in every container's `/etc/resolv.conf` and shows up in the container's own
`netstat` as `127.0.0.11:45117 LISTEN` — only answers for containers that share
a **user-defined** network. The legacy `bridge` network has no service
discovery at all, which is why anything started with a plain `docker run` and
no `--network` can never resolve a compose service name.

The two error codes differ for a reason: `ENOTFOUND` is NXDOMAIN (the resolver
answered "no such name"), `EAI_AGAIN` is a resolution failure/timeout.

**Fix.** Put both containers on the same user-defined network — which is what
compose does by default, and why this only bites people who mix `docker run`
with a compose stack.

**Wrong prediction 3 — "the IP will still route, so it is purely DNS."**
It did not: the TCP connect from the default bridge to `172.21.0.2:5432` hung
for the full 4000 ms timeout. Docker isolates bridge networks in the packet
filter, so it is **both** a name-resolution failure and a connectivity block.

The hang is itself diagnostic, and it is the Scenario A task 8 distinction one
layer down: **4 s of silence = the packets were DROPPED**; a refusal would have
come back as an instant RST (`ECONNREFUSED`).

Locating the rule turned up something worth recording: this host runs
`iptables v1.8.10 (nf_tables)`, and `iptables -S DOCKER-ISOLATION-STAGE-1`
returns **nothing** — the `DOCKER-ISOLATION-STAGE-1/2` chains that every
tutorial names do not exist on modern Docker. The live ruleset instead has
`DOCKER-FORWARD`, `DOCKER-BRIDGE`, `DOCKER-INTERNAL` and `DOCKER-CT` under
`table ip filter`, with per-bridge `iifname … accept` rules. I could not pin
the single dropping rule from the truncated `nft list ruleset` output, so I am
not going to claim one; the observed behaviour (silent drop, no RST) is the
evidence, and the chain names are where to look.

---

#### 28c — volume mounted, the app sees an empty directory

**Symptom.** `Error: Cannot find module 'pg'`, `requireStack: ['/app/src/db.js',
'/app/db/migrate.js']`, and the container crash-loops.

**The command that settles it.** The container is crash-looping, so `exec` is
not available — use a throwaway container with the *same* mount:

```bash
docker run --rm -v "$PWD/docker/drills/empty-folder":/app/node_modules $IMG \
  sh -c 'ls -A /app/node_modules | wc -l'
```

| what | entries in `/app/node_modules` |
| --- | --- |
| with the bind mount | **1** (just the `.gitkeep`) |
| the same image, no mount | **87** |
| an empty **named volume** | **87** |

**Root cause.** A **bind mount replaces** whatever the image had at that path.
It does not merge and it does not overlay; the image's contents are still in
the image, they are simply shadowed for the life of the container.

**The contrast is the part worth knowing.** When a **named volume** is new and
empty, Docker *copies* the image's contents at that path into the volume on
first use — hence 87 entries. But that copy happens exactly once. After that
the volume has its own contents, and a rebuilt image with updated dependencies
is ignored. That is the real explanation for "I added a package, rebuilt, and
it still says module not found". Bind mounts never do the copy, even from an
empty host directory.

**Fix.** Do not mount over `node_modules`. For live-reload development mount
the source only (`./src:/app/src`), or use an anonymous volume to *protect* the
image's copy (`- /app/node_modules`).

---

#### 28d — port published, connection refused from the host

**Symptom.** `docker compose ps` shows `Up (healthy)` and
`0.0.0.0:3120->3000/tcp`, but the host cannot reach it — while the app answers
perfectly from inside:

```
$ docker compose exec app wget -qO- http://127.0.0.1:3000/healthz
{"status":"ok","version":"v1","host":"9182ed82ed53"}
```

**The command that settles it:**

```bash
docker compose exec app netstat -lntp
tcp  0  0  127.0.0.1:3000   0.0.0.0:*  LISTEN  1/node
```

`127.0.0.1:3000` means the **bind address** is wrong. `0.0.0.0:3000` would have
meant "look at the firewall or the publish flag instead". After the fix the
same command prints `0.0.0.0:3000` and the host gets `HTTP 200`. If `netstat`
is missing, `/proc/net/tcp` says the same thing in little-endian hex —
`0100007F` is 127.0.0.1, `00000000` is 0.0.0.0, `0BB8` is 3000.

**Root cause.** The app bound the **container's** loopback interface.
`ports:` DNATs host traffic into the container's network namespace where it
arrives on `eth0` — an interface nothing is listening on. A listener on
127.0.0.1 inside a namespace is unreachable from outside that namespace by
design.

**Fix.** Bind `0.0.0.0` inside the container (`HOST=0.0.0.0`, which is
`server.js`'s default) and restrict exposure with the *publish* address
instead — exactly as the compose file does for Postgres:
`127.0.0.1:5433:5432`.

**Wrong prediction 4 — I expected `curl` exit 7, and got 56.**
My own legend said "7 = refused, 28 = timed out". Neither. Exit **56** is
"failure receiving network data", and `curl -v` shows why:

```
* Trying 127.0.0.1:3120...
* Connected to 127.0.0.1 (127.0.0.1) port 3120
* Empty reply from server
```

`docker-proxy` is a userland process that itself **listens on the host port**
(`ss -lntp` shows `0.0.0.0:3120 users:(("docker-proxy",pid=748836))`). It
accepts the TCP connection first, *then* tries to reach the container and
fails, and closes. So the client sees a successful connect followed by nothing.

Control, on a port with nothing on it at all: `curl` exit **7**, instantly.

That gives three distinct signatures for "I cannot reach it", and Scenario A
only produced two:

| what happened | client sees | exit |
| --- | --- | --- |
| nothing is listening | instant RST | 7 |
| packets dropped (firewall, bridge isolation) | full timeout | 28 |
| a proxy accepts, then cannot forward | connect, then empty reply | **56** |


## B3 — Instrumentation, Prometheus and Grafana

### Task 29 — Metrics

Implementation: [`app/src/metrics.js`](app/src/metrics.js), wired in
[`app/src/server.js`](app/src/server.js). Evidence: `evidence/b3-task29.txt`
from `docker/b3-task29.sh`.

| # | Metric | Type | What it is for |
| --- | --- | --- | --- |
| 1 | `http_requests_total` | Counter | throughput and error rate |
| 2 | `http_request_duration_seconds` | Histogram | latency / p95 |
| 3 | `db_query_duration_seconds` | Histogram | which named query is slow |
| 4 | `db_queries_per_request` | Histogram | **the N+1 detector** |
| 5 | `db_rows_returned` | Histogram | **the unbounded-`limit` detector** |
| 6 | `http_requests_in_flight` | Gauge | saturation |

`in_flight` is a **Gauge** and not a Counter for the obvious reason: it goes
down as well as up. `collectDefaultMetrics` adds the Node process/GC/heap set;
`process_start_time_seconds` out of that is what catches a crash-looping
container, because it moves when nothing else says anything happened.

**Cardinality — the decision that matters most.** The `route` label is always
the route *pattern*, never the requested path:

```js
const route = req.route ? `${req.baseUrl}${req.route.path}` : 'unmatched';
```

Prometheus stores one time series per unique label combination, so labelling
with the path would create a series per note id — 50,000 series from one
endpoint, each carrying a full set of histogram buckets. `req.route` only
exists once Express has matched a handler and it holds the pattern; anything
unmatched is bucketed as `'unmatched'` rather than labelled with whatever URL a
scanner probed. This is not fixable after the fact: once high-cardinality
series are written they are in the TSDB until retention expires.

Tested rather than asserted — the script issues **30 different note ids** and
then fails if any route label contains a path segment that is a number:

```
route="/api/notes"     route="/api/notes/:id"   route="/api/search"
route="/api/stats"     route="/healthz"         route="/metrics"
route="/readyz"        route="unmatched"
PASS -- 30 different note ids produced ONE series, not 30
total series exposed: 662
```

`tenant` is safe as a label for the same reason `user_id` would not be: five
bounded values, and it is the dimension the exam actually asks us to slice by.

**Counting queries per request** uses `AsyncLocalStorage`:

```js
db.requestContext.run({ queries: 0 }, () => { … })
```

It gives a per-request store that survives every `await`, so `db.query()` can
increment a counter that belongs to *this* request. A module-level variable
would be corrupted by concurrent requests. The value is observed in
`res.on('finish')`, once the response is actually complete.

**The N+1, measured.** `GET /api/notes?limit=20` runs one query for the notes
and then one per note for its tags:

```
db_queries_per_request_bucket{le="13",route="/api/notes"}  0
db_queries_per_request_bucket{le="21",route="/api/notes"}  1     <- the jump
db_queries_per_request_bucket{le="34",route="/api/notes"}  3
db_queries_per_request_sum{route="/api/notes"}   65
db_queries_per_request_count{route="/api/notes"}  3      -> mean 21.67
```

Zero through `le=13` and then a jump is the signature. The `21` bucket boundary
exists precisely so that this shape is legible instead of being smeared across
a 10–50 bucket. Compare a route without the problem:

```
db_queries_per_request_bucket{le="2",route="/api/notes/:id"} 29
db_queries_per_request_bucket{le="3",route="/api/notes/:id"} 30   -> mean 2.03
```

The same problem seen from the other metric: `db_rows_returned` shows
`notes_list` with **count=3** and `tags_for_note` with **count=90** — ninety
round trips where three would do.

**The totals reconcile exactly, and that is the check that the instrumentation
is honest**, not just plausible:

| route | arithmetic | total |
| --- | --- | --- |
| `/api/notes` ×3 | acme (tenant cached) 1+20=21; globex 1+1+20=22; initech 22 | **65** ✓ |
| `/api/notes/:id` ×30 | first 1+1+1=3, then 29 × 2 | **61** ✓ |

**Three mistakes worth recording.**

1. & 2. **Grepping the exposition format.** I wrote the verification greps
   against an assumed label order, twice. `_sum`/`_count` are emitted as
   `{app="…",route="…"}` but `_bucket` as `{le="…",app="…",route="…"}` — `le`
   comes **first**. My first attempt anchored on `{route=`; my second matched
   `route="/api/notes",` with a trailing comma, when `route` is the last label
   and is followed by `}`. Both printed nothing at all, which is
   indistinguishable from a missing metric — I briefly suspected the app had
   restarted and checked `process_start_time_seconds` before finding the real
   cause. Never assume label order; anchor on `}`.

3. **I predicted `le="21"` would be 0 on a fresh process** and it was 1. The
   script runs the 30 `/api/notes/:id` requests *before* the list requests, and
   those warm the acme tenant cache, so acme's list request costs 21 while the
   two cold tenants cost 22. The metric was right; my model of the traffic was
   not. It is the same lesson I had just written down for task 26: a number is
   only interpretable if you know what happened before it.

**One thing this run exposed for later.** `db_rows_returned{query_name="search_notes"}`
has `sum=0` over 3 calls — `?q=alpha` can never match, because seeded bodies
are concatenated md5 hex (`0-9a-f` only). Task 31's load generator therefore
has to use hex fragments, and it has to use *rare* ones: a common fragment like
`ab` fills `LIMIT 50` early and Postgres stops scanning, hiding the very
sequential scan that deliberate problem 2 is about.

### Task 30 — Prometheus

Config: [`docker/prometheus.yml`](docker/prometheus.yml). Evidence:
`evidence/b3-task30.txt` from `docker/b3-task30.sh`. Everything below is read
back out of Prometheus's own HTTP API rather than from the UI looking green.

```yaml
scrape_configs:
  - job_name: notes-api
    static_configs:
      - targets: ['app:3000']
```

`app` is the compose **service name** and `3000` is the port **inside** the
container, not the published 3120. Docker's embedded DNS resolves it because
both containers are on the same user-defined network — the mechanism proven in
B2 task 28b. `localhost:3000` would be Prometheus's own container.

`scrape_interval: 5s` instead of the 15 s default because this exam's load runs
for minutes: at 15 s a p95 graph has too few points to read. In production 15 s
is the right answer — the scrape interval is a storage cost.

**Result:**

```
job=notes-api    health=up   url=http://app:3000/metrics
   interval=5s   lastDuration=0.0293s   lastScrape=2026-09-03T18:58:29Z
job=prometheus   health=up   url=http://localhost:9090/metrics

up  ->  1  {instance="app:3000", job="notes-api", service="notes-api"}
head series: 1352
```

`lastError` is empty and `up` is 1, which is also the only DNS proof worth
having here — see the note on `nslookup` below.

**The queries that matter.**

```promql
sum by (route) (http_requests_total)
sum(rate(http_requests_total[1m]))                                   -> 1.02 req/s
histogram_quantile(0.95, sum by (route,le) (rate(http_request_duration_seconds_bucket[1m])))
rate(db_queries_per_request_sum[1m]) / rate(db_queries_per_request_count[1m])
```

The last one is the general form for reading a mean out of any histogram: both
`_sum` and `_count` are counters, so each needs its own `rate()` before the
division. Dividing the raw counters would give the average since process start
instead of the average right now.

| route | mean DB queries/request | p95 latency |
| --- | --- | --- |
| `/api/notes` | **21.0** | **0.833 s** |
| `/api/notes/:id` | 1.0 | 0.008 s |
| `/healthz` | 0.0 | 0.009 s |

A hundredfold latency difference, and the query-count column says why. This is
the N+1 from task 29, now visible in PromQL rather than in raw exposition text.

**Three things I got wrong or had to explain.**

1. **`external_labels` are not on local series.** I queried `up{env="exam"}`
   expecting a match and got nothing. That is correct behaviour:
   `external_labels` are attached only when data *leaves* this Prometheus —
   remote_write, federation, and alerts sent to Alertmanager — and are never
   written into the local TSDB. `/api/v1/status/config` confirms `env: exam` is
   loaded. It becomes visible in task 33, where the alert notification carries
   it.

2. **`nan` in the per-route means** is not an error. For a route with no
   traffic in the window, `rate(_sum)/rate(_count)` is 0/0. Grafana panels have
   to be told to hide it rather than draw a gap-shaped lie.

3. **`/api/notes/:id` showed a mean of 1.0 query, not the 2.0 I expected.**
   Checked instead of hand-waved:

   ```
   sum by (status) (http_requests_total{route="/api/notes/:id"})
     status=200  30
     status=404  40
   ```

   The load loop asked for ids 1–20 as tenant `globex`, but ids 1–20 all belong
   to `acme` (it is seeded first, with 30,000 of the 50,000 notes). A 404 skips
   the tags query, so those requests cost one query, not two.

   Two consequences. It is incidental proof that **cross-tenant isolation
   works** — globex cannot read acme's rows. And it is a warning for task 31:
   a load generator that picks ids without regard to tenant produces mostly
   404s, never triggers the N+1, and would have measured nothing at all.

**Tooling note.** The formatter for these API responses lives in
[`docker/promfmt.py`](docker/promfmt.py) rather than in `python3 -c '…'`. Inside
a single-quoted shell string every double quote in the Python needs a
backslash, and `\"` inside an f-string expression is a `SyntaxError`. Eight of
my nine inline formatters died that way in the first run while the data behind
them was perfectly fine — a reminder that a broken *reporter* looks exactly
like a broken *system*.

Also worth recording: `nslookup app` inside the Prometheus container answers
`Can't find app: No answer` **while scraping that exact name works**. busybox's
resolver behaves oddly against Docker's 127.0.0.11. Same trap as B2 task 28b —
never let a quirky applet stand in as proof of absence.

### Task 31 — Load

[`app/loadtest.sh`](app/loadtest.sh) — 5 minutes, every endpoint, 5 tenants,
with a **30-second burst** at the halfway mark (20 extra concurrent workers) for
the saturation panel, and **acme as the deliberately bad tenant**. Evidence:
`evidence/b3-task31-load.txt`.

**Final run:**

```
6215 requests over 300s        status 200: 6280      status 499: 75      404: 0

mean DB queries per request        rows returned per query
  /api/notes        36.47            notes_list      mean   239.7 over  1,263 calls
  /api/notes/:id     2.00            tags_for_note   mean     2.9 over 99,884 calls
  /api/search        1.00            search_notes    mean     1.1 over  1,243 calls
  /api/stats         1.00            note_by_id      mean     1.0 over  1,243 calls
  /healthz           0.00
```

`notes_list` 1,263 calls against `tags_for_note` 99,884 is the N+1 in one line:
a **79× amplification** on the read path.

The first version of this run was wrong in four separate ways, and none of them
announced themselves. All four were found by making the numbers reconcile.

**1. Ids were derived from `min`/`max` per tenant.** That printed
`acme 1..50003`. acme really owns 1..30000; 30001..50000 belong to the other
four tenants and 50001..50003 are the three marker notes B2 task 27 inserted.
`min`/`max` describes a *range* only if the ids are contiguous, and task 27
destroyed that. Ids are now **sampled** — 100 real ids per tenant via
`JOIN LATERAL (SELECT id … ORDER BY random() LIMIT 100)` — which cannot be
wrong however the ids are laid out. 404s went from 25 to **0**, and
`/api/notes/:id` moved from a mean of 1.98 queries to exactly **2.00**, because
every request now finds its note and runs the tags query.

**2. `$RANDOM` maxes out at 32767.** `RANDOM % 50003` can never exceed 32767,
so ids above that were unreachable and ids 30001–32767 (another tenant's) were
being requested — the exact 25 404s observed. Silent truncation; sampling
sidesteps it entirely.

**3. The search term was `abc`.** Seeded bodies are concatenated md5, so a
3-hex fragment matches thousands of rows, `LIMIT 50` fills within the first
couple of thousand rows scanned, and Postgres **stops** — hiding the sequential
scan that deliberate problem 2 is about. A random **5-hex** fragment matches
almost nothing, so the scan runs to the end. The slow path is the honest one.

**4. The pathological request was sent every time, and had to be throttled to a
tail.** The tag loop is `for … await`, strictly sequential, so `?limit=5000` is
5001 round trips holding a pool connection for minutes. Sent once a second it
would keep the app saturated for the whole five minutes: everything times out,
the burst disappears, and every panel shows the same flat wall. It is now one
in five of acme's list requests, which puts a clear 5000 tail in
`db_rows_returned` and a visibly worse p95 on acme, while the burst still
stands out. Pathology shows up in production as a tail, not as a distribution.

**What the load run then exposed in the instrumentation itself.** Two counts
that should have been equal were not: `notes_list` ran **1218** times while
`http_requests_total{route="/api/notes"}` counted **1158**. Sixty requests did
work and left no trace. Three bugs, in one middleware block:

- **`res.on('finish')` never fires for a client-aborted request.** Every
  `?limit=5000` and burst request was cut off by curl's `--max-time 30`, so the
  slowest requests in the system — the only ones anyone cares about — were
  recorded in neither `http_requests_total` nor `db_queries_per_request`. It is
  survivorship bias built into the monitoring: the dashboard silently drops the
  requests that are going wrong. Now `res.on('close')`, which fires in both
  cases, with **status 499** (nginx's "client closed request") when
  `res.writableEnded` is false. Leaving them as 200 would be worse than not
  counting them.
- **`in_flight` leaked.** It was incremented unconditionally and decremented
  only on `finish`, so every aborted request left the gauge one higher forever.
  Measured directly after the run: **63**, with the true value 0. The saturation
  panel would have drifted upwards all day and never come back.
- **The `AsyncLocalStorage` store was read inside the listener.** Moving to
  `close` broke the query count in exactly the case being fixed:
  `getStore()` returned `undefined`. `finish` is emitted from inside
  `res.end()`, still in the request's async context; `close` after an abort is
  emitted from the **socket** teardown, a different context. The store is now
  captured synchronously in the middleware and held in the closure — `ctx` is a
  plain object that `db.query()` mutates, so the reference is enough.

Verified one at a time: a completed request and an aborted one, with the
aborted one appearing as `status="499"`, the query count recorded, and
`in_flight` returning to 0.

**A limit that remains, quantified.** For an aborted request
`db_queries_per_request` records the count **at the moment of the abort**, not
the work the server goes on to do. In the final run `/api/notes` recorded
1,263 × 36.47 ≈ **46,000 queries**, while the per-query metrics show
98,641 `tags_for_note` + 1,263 `notes_list` ≈ **99,900** actually executed. The
per-request metric therefore sees about **46%** of the real database load. Both
kinds of metric are needed: per-request for user experience, per-query for what
the database is actually being asked to do.

**And the underlying reason the server keeps going:** hanging up on an HTTP
request does not cancel it. A `curl --max-time 3` against `?limit=5000` left
the app running its remaining queries for another 40 seconds, for a response
nobody would read. The real fix is to abort the work on `res.on('close')`;
noted in INCOMPLETE.md rather than claimed.

**Measured while diagnosing this, and it sets up task 34.** A single
`tags_for_note` takes roughly **40 ms**, because `tags.note_id` has no index
(deliberate problem 3) and each lookup sequentially scans all 150,000 tag rows.
That multiplies with the N+1: 21 queries × 40 ms ≈ **0.833 s**, which is
exactly the p95 measured for `/api/notes` in task 30. `?limit=2000` did not
finish inside a 120-second timeout. The two deliberate problems are not
additive, they are multiplicative — N queries, each a full table scan.

### Task 32 — The dashboard

[`grafana/dashboard.json`](grafana/dashboard.json), provisioned from
[`grafana/provisioning/`](grafana/provisioning/). Nine panels, `route` and
`tenant` template variables, and a deploy-annotation toggle. Evidence:
`evidence/b3-task32.txt` plus the dashboard screenshots.

Provisioning pins the datasource **uid to `PROM_EXAM`**, and the dashboard JSON
references that uid. Without pinning, Grafana generates a random uid and an
imported dashboard shows "Datasource not found" on every panel — the usual
reason an exported dashboard is blank on someone else's machine. Verified
through Grafana's own API:

```
/api/health                       database: ok, version 11.2.0
/api/datasources                  uid=PROM_EXAM  url=http://prometheus:9090
/api/datasources/uid/PROM_EXAM/health   "Successfully queried the Prometheus API"
/api/search                       uid=notes-api-exam  title=exam-root-vmi…1536d427
```

**A screenshot proves the dashboard exists; it does not prove the panels
work.** A mistyped metric name draws an empty panel, not an error, and a
screenshot taken in a quiet minute looks identical. So
[`docker/b3-panels.py`](docker/b3-panels.py) reads the dashboard JSON, extracts
every target, substitutes `$__rate_interval`, and evaluates all of them against
Prometheus — printing the datasource uid per target as it goes. Result:
`every panel target returned data`.

| Panel | What it showed under load |
| --- | --- |
| A — p95 by endpoint | `/api/notes` mean **22.1 s**, max **58.5 s**; `/api/notes/:id` 387 ms; `/api/search` 253 ms |
| B — seconds of work per second | `/api/notes` **3.27** mean, **59.5** peak; next endpoint 0.56 |
| C — query mean vs p99 | `tags_for_note` mean 62.7 ms against p99 236 ms; `notes_list` 83.3 / 201 ms |
| D — slowest query and its rate | `stats_join` p99 **837 ms** at **4.36 req/s**; `tags_for_note` p99 **239 ms** at **328 req/s** |
| E — N+1 detector | `/api/notes` mean **96.9**, max **468**; every other route flat at 1–2 |
| F — queries slower than 50 ms | `tags_for_note` **102 req/s** mean, **358 req/s** peak; everything else under 1 |
| G — rows returned | `notes_list` p50 **15.4**, p99 peaks near **4,000** |
| H — by tenant | acme p95 **27.0 s** (max 58.5 s) against globex **2.18 s**, hooli **2.32 s** |
| I — saturation | in-flight max **55**, p95 max **56.6 s**, and the latency peak *lags* the concurrency peak |

**Panel B is the one that decides what to fix**, not A. A ranks "slowest per
request"; B is `rate(_sum)`, which is latency × call rate — where the server's
time actually goes. An endpoint that takes five seconds but runs twice a day is
not the problem.

**Panel D makes the same point one layer down, and it is the sharpest number on
the dashboard.** `stats_join` is 3.5× slower *per call* than `tags_for_note`,
so a "slowest query" list would put it first. But 0.837 × 4.36 ≈ **3.6 s/s** of
database time against 0.239 × 328 ≈ **78 s/s**. `tags_for_note` costs about
**22× more total time**. The slowest query is not the one to fix; the one to fix
is duration × frequency, which is why both columns are on one panel.

**Panel F's threshold has to be an existing bucket boundary.**
`count(all) - count(le="0.05")` is the rate of queries in the tail above 50 ms,
and 0.05 is a real edge in `db_query_duration_seconds`. Asking for 0.06 would
return nothing at all, silently, because no such bucket exists.

**Panel I answers a question A cannot.** Concurrency on the left axis, latency
on the right. The two peaks are not simultaneous: in-flight peaks first and p95
follows. That lag is queueing — work waiting for a resource rather than each
request individually costing more — and the resource is the connection pool,
`PG_POOL_MAX=10` with 55 requests in flight. If latency had risen *with*
concurrency instead, the answer would have been per-request work.

**Three bugs found by looking at the finished dashboard, each with a fix.**

1. **Panels A and H reported a p95 of exactly `10`.** Not a coincidence: 10 was
   the top bucket of `http_request_duration_seconds`, and when the quantile
   falls in the `+Inf` bucket `histogram_quantile` returns the highest *finite*
   boundary. Proved before touching anything:

   ```
   le="10"    acme 293      globex 325   initech 313
   le="+Inf"  acme 408      globex 325   initech 313
   ```

   115 of acme's requests — 28% — were slower than 10 s, so its p95 was
   genuinely off the end of the histogram, while globex's 4.1 s was a real
   measurement. Buckets now extend to `15, 30, 60`, and the same p95 measured
   **43.7 s**. The dashboard had been understating the worst case by more than
   4×. A histogram can only ever report what its buckets can express, and this
   is the direction that matters: it under-reports, so it looks healthy.

2. **Panel H's error rate matched only `status=~"5.."`.** After task 31 made
   client aborts visible as `499`, the tenant panel was excluding exactly the
   failures that task had just surfaced. Now `status=~"5..|499"`, and acme's
   error rate reads 22%.

3. **Panel D rendered 363 calls/sec as "6.06 mins".** The panel default unit is
   seconds, correct for the p99 column, and the joined `calls/sec` column
   inherited it. The number was right and the label was a lie — worse than a
   blank panel, because a blank panel makes you investigate. Fixed with a
   `reqps` unit override on that field, plus hiding the two `Time` columns that
   the `joinByField` transformation leaves behind (both carry the same
   evaluation timestamp and tell the reader nothing).

**One property of table panels worth knowing.** Panel D's targets are *instant*
queries, so during a quiet minute every cell reads `NaN` / `0 req/s`. That is
correct, not broken — but it means the table is only meaningful while traffic
is flowing, which is why the final screenshots were taken with the load
generator running.

**Panel screenshots under load:**
[`evidence/b3-task32-panels-top.png`](evidence/b3-task32-panels-top.png) (panels
A–C) and
[`evidence/b3-task32-panels-bottom.png`](evidence/b3-task32-panels-bottom.png)
(D–H). The first pair I took were retaken: they were captured during an idle
window, so panels D–G were empty and a dashboard with no data is exactly what
the brief calls out as a viva trigger. These are taken with `loadtest.sh`
running.

### Task 33 — The alert

Two copies of the same condition, deliberately:
[`docker/alert.rules.yml`](docker/alert.rules.yml) (Prometheus) and
[`grafana/provisioning/alerting/alerts.yml`](grafana/provisioning/alerting/alerts.yml)
(Grafana-managed, provisioned from a file rather than clicked together, so it
is reproducible and in git). The Prometheus copy keeps firing when Grafana is
down, which is exactly when you want to hear from it; the Grafana copy is what
a person watches. Evidence: `evidence/b3-task33.txt`.

**The threshold, from measured baselines rather than a round number:**

| | `/api/notes` | `/api/search` | `/api/notes/:id` | `/healthz` |
| --- | --- | --- | --- | --- |
| light traffic p95 | 0.83 s | 0.25 s | 0.008 s | 0.009 s |
| under load p95 | 22–43 s | 0.4–0.9 s | 0.4–0.9 s | — |

`> 1.5s` is about **1.8× the worst healthy p95** and far below anything seen
while degraded. Lower — say 1 s — and `/api/notes` pages on an ordinary busy
minute. Much higher — say 20 s — and a route that normally answers in 8 ms
could get a hundred times slower unnoticed.

`for: 2m` is 24 consecutive evaluations at the 5 s `evaluation_interval`. One
slow scrape or one unlucky burst must not wake anybody.

**The state machine, caught live.** Showing an alert "firing" proves nothing
about understanding `for:`; catching **pending** does.

```
22:14:25  HighP95Latency /api/notes   pending    4.88
22:16:26  HighP95Latency /api/notes   firing     9.83     <- 2m01s after pending
22:19:00  load stopped
22:19:29  HighP95Latency /api/notes   firing     (last)
22:19:44  (gone -- resolved on its own)
```

Grafana's own API agreed at the same moment: `"state":"firing"` /
`"Alerting"`, every other rule `Normal`.

**A cascade the timeline shows and no single panel does:**

```
22:16:26  /api/notes       firing
22:17:12  /api/notes/:id   pending
22:17:42  /api/stats       pending
22:18:58  /api/search      pending
```

One endpoint's N+1 exhausts the connection pool and routes with no problem of
their own cross the threshold behind it. That is panel I's queueing lag,
confirmed from a completely different direction.

**The bug this task found in its own alert.** `HighErrorRate` fired at
**22:22:00 — three minutes after the load stopped.**

A ratio over a rate window keeps rising once traffic dries up, because the
denominator collapses. It is worse than usual here: 499s are by definition the
*slow* requests, completing ~30 s after they were issued, while 200s complete
immediately. As the 5-minute window slides forward, the successes age out of it
first and the failure ratio **increases during the quiet period**. An alert
that goes off after the incident is over is precisely how people are trained to
ignore alerts. Fixed with a minimum-traffic guard:

```promql
( sum by (route) (rate(http_requests_total{status=~"5..|499"}[5m]))
  / sum by (route) (rate(http_requests_total[5m])) ) > 0.05
and
  sum by (route) (rate(http_requests_total[5m])) > 0.2
```

0.2 req/s is one request every five seconds; below that a ratio is meaningless
anyway — one failure in three requests is "33% errors" and means nothing.

The rule also matches `status=~"5..|499"` rather than `5..` alone. After task 31
made client aborts visible, an error-rate alert that ignored them would have
been blind to the worst failure the service produces. During the load run
`/api/notes` sat at 6–8% by this definition and 0% by the 5xx-only one.

**Two honest notes about this evidence.**

1. `activeAt` for `HighErrorRate` was 22:14:09 and `for` is 5m, so it should
   have fired at 22:19:09; it fired at 22:22:00. The condition must therefore
   have dropped below 0.05 at least once in between and restarted the timer —
   probably around 22:17:00. I could not see it happen: Prometheus evaluates
   every 5 s and my sampling loop ran every 15 s. I am recording the
   inference, not claiming the observation.
2. The `VALUE` column in the transcript is **wrong for `HighErrorRate`**, and
   the transcript is kept as it was rather than re-run. My sampling script
   printed `a["value"][:12]`, which truncated `8.225108225108226e-02` to
   `8.2251082251` — chopping the exponent and rendering 8.2% as 822%. Same
   class of error as the Grafana unit that displayed 363 req/s as "6.06 mins":
   the value was right and the rendering lied. The script now formats with
   `"{:.4g}"`. Every `HighErrorRate` number in that transcript should be read
   as ×10⁻².

**A design note on the Grafana copy.** `noDataState: OK`, not `Alerting`. A
route nobody called has no p95, and paging because "nobody used /api/search
this minute" is the same failure mode as the one above. The case that actually
matters — the target being gone — is covered by `AppDown` on
`up{job="notes-api"} == 0`, which is a positive statement about the scrape
rather than an absence of data.

### Task 34 — Fix one problem and prove it

Problem fixed: **3 — the missing index on `tags.note_id`**. Chosen from the
dashboard rather than from reading the code: panel D showed `tags_for_note` at
**328 req/s** against ~4 req/s for everything else, and panel F showed up to
**358 req/s** of those exceeding 50 ms. Duration × frequency, not duration.
Evidence: `evidence/b3-task34.txt`, `evidence/b3-task34-writecost.txt`.

```sql
-- before
EXPLAIN (ANALYZE, BUFFERS) SELECT name FROM tags WHERE note_id = 12345;
 Seq Scan on tags  (cost=0.00..2739.04 rows=4) (actual time=0.080..19.077 rows=6)
   Filter: (note_id = 12345)
   Rows Removed by Filter: 149997
   Buffers: shared hit=864
 Execution Time: 19.135 ms

CREATE INDEX idx_tags_note_id ON tags (note_id);     -- 2634.9 ms
ANALYZE tags;                                        --   56.2 ms

-- after
 Bitmap Heap Scan on tags  (cost=4.33..19.58 rows=4) (actual time=0.067..0.113 rows=6)
   Heap Blocks: exact=6
   Buffers: shared hit=7 read=1
   ->  Bitmap Index Scan on idx_tags_note_id (actual time=0.053..0.053 rows=6)
 Execution Time: 0.211 ms
```

**The plan changing is the proof; the timing is the consequence.** `Rows
Removed by Filter: 149997` is the whole problem in one line — Postgres read
every tag row in the table to return six.

| Measurement | Before | After | Improvement |
| --- | --- | --- | --- |
| `EXPLAIN` execution time | 19.135 ms | 0.211 ms | **91×** |
| **Buffers touched** | **864** | **8** | **108×** |
| 100 sequential lookups | 2474.9 ms | 25.0 ms | **99×** |
| `GET /api/notes?limit=20` | 2.255 s | 0.283 s | **8×** |
| `GET /api/notes?limit=2000` | **> 120 s (timed out)** | **16.06 s** | — |

**Buffers, not milliseconds, is the number to quote.** Wall-clock moves with
cache warmth, with load, and on this shared VPS with whatever the other
students are doing. `864 → 8` buffers is a direct count of work performed and
is nearly immune to all of that. `ANALYZE tags` matters as much as the
`CREATE INDEX`: the planner chooses on statistics, and with stale ones it will
keep picking the sequential scan it has always picked. That is the real reason
behind "I added an index and nothing got faster".

**Why the index was missing at all.** Postgres does **not** index the
*referencing* side of a foreign key. The constraint needs a unique index on the
*referenced* side — `notes.id`, the primary key, which exists — and the
referencing column gets nothing. So `tags.note_id` was unindexed despite being
a declared foreign key. The same gap also makes `DELETE FROM notes` slow, since
each delete has to scan `tags` to check the constraint.

**What the fix cost on disk:** index **2216 kB** against a 7744 kB heap — about
29%, and `pg_total_relation_size('tags')` went from 11 MB to 13 MB.

**What the fix cost on writes — and how I got that wrong twice.**

*First attempt:* 10,000-row INSERT took **731.6 ms** before and **464.7 ms**
after. The index apparently made writes faster, which is not possible. The
measurement was unfair: the "before" run extended the heap into fresh pages
with a cold cache, then 10,000 rows were DELETEd, leaving free space that the
"after" run reused. The heap grew only 512 kB across 20,000 inserted rows,
which gives it away.

*Second attempt:* three runs per condition, `VACUUM` before each, conditions
alternated so any drift hit both sides equally.

```
with index:     345, 445, 388 ms      spread 100
without index:  539, 383, 931 ms      spread 548
```

**Inconclusive, and that is the finding.** The run-to-run spread without the
index (548 ms) is larger than any plausible effect. On a shared VPS the noise
floor is above the signal. The means would have said "the index makes INSERTs
faster", which is nonsense — a good demonstration that averaging noisy
measurements does not make them meaningful.

*Third attempt — stop timing, count work.* `Buffers` did that job for reads;
`EXPLAIN (ANALYZE, BUFFERS, WAL)` does it for writes.

| 10,000-row INSERT | with index | without index | difference |
| --- | --- | --- | --- |
| WAL records | 30,461 | 20,357 | **+10,104** |
| WAL bytes | 2,076,606 | 1,421,894 | **+46%** |
| Buffers | 50,509 | 30,481 | **+20,028** |
| Execution time | 439 ms | 395 ms | *inside the noise* |

Run a second time (`evidence/b3-task34-wal.txt`), the point makes itself:

| second run | with index | without index |
| --- | --- | --- |
| WAL records | 30,462 | 20,357 |
| WAL bytes | 2,096,852 | 1,421,894 |
| Execution time | 367 ms | 371 ms |

The `without` figures are **identical to the first run, to the byte**, and the
`with` record count differs by one. The execution times, meanwhile, came out
367 ms against 371 ms — this time the timing would have said the index costs
*nothing at all*. Two runs, two contradictory answers from the clock and the
same answer twice from the counters.

(`fpi=3` in the second run is full-page images: the first write to a page after
a checkpoint logs the whole page. It nudges WAL *bytes* around depending on
where the checkpoint fell, which is why the *record count* is the cleaner
signal of the two.)

`+10,104` WAL records over 10,000 inserted rows is **one extra WAL record per
row** — the b-tree insertion — plus about two extra buffer touches each. That
is the honest cost: roughly 46% more write-ahead log for this table. Real, and
completely invisible to a stopwatch on this machine.

For this workload — read-heavy, writes rare, `tags_for_note` at 328 req/s
against occasional inserts — 46% more WAL to remove 108× the read work is not
a close call. For a write-heavy append-only log it might be, and that is the
actual argument against indexing everything by reflex.

**Which problem I would fix next, and what I would measure first.**

Next: **the N+1 (problem 1)**. The index makes each of the 21 queries fast,
which *masks* the N+1 in a latency graph — and the measurement above shows
exactly that: `?limit=2000` went from "does not finish in 120 s" to **16.06 s**,
which is 2001 round trips at about 8 ms each. Still 2001 round trips. Panel E
shows it plainly where panel A no longer does, which is the argument for
keeping a queries-per-request metric permanently.

Before doing it I would measure:

1. `db_queries_per_request` at the limits real clients use, to confirm it
   scales with `limit` rather than being fixed overhead.
2. The share of `/api/notes` latency actually spent in `tags_for_note`. If tags
   are 10% of the request, the N+1 is not the bottleneck.
3. Round-trip latency to the database. The N+1 is a *round trip* problem: at
   0.1 ms it is nearly free, at 2 ms across an availability zone it dominates —
   which is why the same code is fine in dev and awful in production.
4. The p99 of `limit`, because the cost is linear in it. `?limit=5000` is 5,001
   queries: problems 1 and 4 multiplying each other.

Fixing the N+1 and the unbounded limit together is worth more than either
alone. The metrics show that; reading the code does not.

---

## B4 — Swarm

Stack file: [`docker/stack.yml`](docker/stack.yml).

### Task 35 — Deploy

**Nodes used: ONE.** A single-node swarm on the exam VPS — the brief allows it
("single node is fine") and I chose it deliberately over building a second node
with Docker-in-Docker, because the remaining budget is better spent on B5 and
Scenario C than on debugging overlay networking between nested daemons. What
one node cannot demonstrate is stated in full below rather than glossed over.

Evidence: `evidence/b4-task35.txt` from `docker/b4-task35.sh`.

```
ID                          HOSTNAME    STATUS  AVAILABILITY  MANAGER STATUS  ENGINE
krmj8bc57xasj0o4k2depeemg * vmi3536696  Ready   Active        Leader          29.7.2

NAME                   MODE        REPLICAS  IMAGE                          PORTS
abdur_notes_app        replicated  3/3       ghcr.io/rasel-xs/notes-api:v1  *:3140->3000/tcp
abdur_notes_postgres   replicated  1/1       postgres:16-alpine

HTTP/1.1 200 OK
X-Served-By: 7cce466a4db8
X-App-Version: v1
```

**Namespacing on a shared host.** Stack `abdur_notes` (services
`abdur_notes_app`, `abdur_notes_postgres`), published port **3140** (3120
belongs to the compose stack), overlay `abdur_notes_notes_net`. One thing here
is **not** namespaceable: `docker swarm init` is daemon-wide state. There is no
per-user swarm. The consequence is that `docker swarm leave --force` would
destroy every stack on this host, not only mine, so it is never run here;
cleanup is `docker stack rm abdur_notes`.

**The image comes from a registry, and that was verified against the registry
rather than against `docker images`.** `docker stack deploy` ignores `build:`
entirely — no warning, the service simply never starts on a node that cannot
get the image. A local tag would in fact have worked here, because on one node
the manager is also the only worker and the image is already on disk; that is
exactly the assumption that breaks the first time a second node appears, so it
was not used. `docker images` only proves a local tag exists — a failed push
leaves one behind — so the check is `docker manifest inspect`, which asks the
registry:

```
v1   present in registry
v2   present in registry
v3   present in registry
```

`--with-registry-auth` passes the login into the service spec so tasks can pull
the private GHCR image. On a single node it appears to work without the flag,
because the manager daemon already holds the credentials — which is precisely
why it is easy to forget until a second node exists.

**Convergence took 15 seconds**, and the order is worth noting:

```
14:54:15  app 0/3   postgres 0/1
14:54:20  app 0/3   postgres 1/1
14:54:30  app 3/3   postgres 1/1
```

Postgres became ready first and the app followed. **Swarm has no `depends_on`
at all** — no equivalent of the `condition: service_healthy` that fixed B2
task 26. The app converged anyway because `db/migrate.js` retries for 60
seconds on its own. That is the reason the retry loop was not redundant with
the compose healthcheck: here it is the only thing doing the job.

**A secret leaked into the evidence, and what was done about it.**
`docker swarm init` prints a worker join token on success. It went into
`evidence/b4-task35.txt` and would have been committed to GitHub. That token
plus the server IP is enough for anyone to join the swarm as a worker and run
containers on this host — it is a credential, not an identifier.

Fixed in the order that matters: **rotate first, redact second.**

```bash
docker swarm join-token --rotate worker
docker swarm join-token --rotate manager
sed -i 's/SWMTKN-[A-Za-z0-9-]*/SWMTKN-<REDACTED-AND-ROTATED>/g' evidence/b4-task35.txt
```

Rotation invalidates the leaked token immediately, so redaction is only the
second line of defence; a redacted-but-live token is still a live token.
Rotation does not disturb running nodes — join tokens are for *joining*, and
existing members authenticate with their own certificates, which the `3/3`
after rotation confirms. The general lesson is that command output cannot be
piped into evidence unexamined: `swarm init`, `docker login`, `kubeadm init`
and their relatives all print secrets on the happy path.

**What one node cannot show**, stated plainly rather than left implied:

- no real high availability — three replicas in one failure domain;
- no scheduling across nodes, so `placement.constraints` beyond
  `node.platform.os` is untested;
- no node-failure rescheduling;
- the registry requirement is satisfied but not *exercised*: nothing here would
  have failed if the image had only been local.

### Task 36 — Scale to 5

`docker service scale abdur_notes_app=5`, then 50 requests. Evidence:
`evidence/b4-task36.txt`.

The brief hints that keep-alive can pin every request to one backend. Rather
than take the hint on faith I ran it three ways, because two things differ
between "loop of curls with `Connection: close`" and "one curl reusing a
connection" — the header, and the process boundary — and only a control
separates them.

| | how the 50 requests were issued | result |
| --- | --- | --- |
| **A** | 50 separate `curl`, `-H "Connection: close"` | **10 / 10 / 10 / 10 / 10** across 5 container ids |
| **B** | **one** `curl` given the URL 50 times | **50 / 50 on a single container** |
| **C** | 50 separate `curl`, **no** header | **10 / 10 / 10 / 10 / 10** — identical to A |

```
--- A ---
     10 X-Served-By: f1dd6babef28        --- B ---
     10 X-Served-By: 775f70fe5661             50 X-Served-By: 57b6b131deec
     10 X-Served-By: 57b6b131deec
     10 X-Served-By: 2d2fffe4bda6
     10 X-Served-By: 10917017bc66
```

Exactly ten each — IPVS round-robin, no jitter at all over 50 samples. The five
hostnames match the five container ids `docker ps` reports for the service.

**The hint is right about the mechanism and wrong about the fix.** C is
identical to A, so `Connection: close` changed nothing: each `curl` is a
separate process that opens its own socket regardless of the header. What
actually pins traffic is **one client reusing one connection**, which is what B
does. The rule underneath:

> The routing mesh load balances per **connection**, not per **request**.

That matters beyond this test. A real client with an HTTP keep-alive pool —
every language's default HTTP client, and every service-to-service call —
holds connections open and will keep hitting the same replica until the
connection is recycled. Scaling out does not rebalance existing connections.
`EndpointSpec` confirms the mode: `{"Mode":"vip", … "PublishMode":"ingress"}` —
a virtual IP with IPVS behind it, not per-request proxying.

**Something happened during the scale that I could not fully explain, so it is
recorded as a hypothesis rather than a finding.** Going from 3 to 5 replicas,
the three *existing* tasks were also replaced:

```
abdur_notes_app.1       Running  22 seconds ago
 \_ abdur_notes_app.1   Shutdown 31 seconds ago
```

What I established:

- They did not crash. `docker inspect` on each shut-down task gives
  `"Message": "shutdown"` and **`"ExitCode": 0`** — an orderly SIGTERM that the
  app's shutdown handler processed cleanly.
- `UpdateStatus` is `null`, and the image digest in `Spec` and `PreviousSpec`
  is identical, so no image change triggered it.
- **It is not inherent to scaling.** Control: scaling 5 → 6 afterwards left all
  five running tasks untouched and added only task 6.

The leading hypothesis is that the first reconcile after `stack deploy`
resolved the `:v1` tag to a digest (`@sha256:d6f7c905…`, which is what the spec
holds now), so the tasks created before resolution no longer matched the stored
spec and were replaced on the next reconciliation — which the 3→5 scale
triggered. I could not confirm that, and I am not going to present it as
though I had.

What matters for task 40 is settled either way: **scaling does not by itself
disturb running tasks**, so any failures counted while scaling down are
attributable to the scale-down itself.

**Operational note.** `docker service scale` without `--detach` prints
`overall progress:` and `verify: Waiting N seconds…` on every poll — about a
hundred lines that made the first transcript nearly unreadable. Later scale
commands use `--detach` and poll `docker service ls` instead.

### Task 37 — Rolling update

`docker/b4-task37.sh` runs the traffic loop and the update from one place, so
the gap between "update issued" and "first v2 response" is measured rather than
eyeballed across two terminals. Every log line is `TIME CODE VERSION HOST`, all
four from a single request — `/healthz` returns `{"status","version","host"}`
and `-w` appends the code — so the same log that proves there was no downtime
also shows the version flipping.

**Result (run 2, `evidence/b4-task37.txt`;** the raw per-request log of all 421
responses is [`evidence/b4-task37-update-log.txt`](evidence/b4-task37-update-log.txt),
and run 1's is
[`evidence/b4-task37-run1-update-log.txt`](evidence/b4-task37-run1-update-log.txt)**)**

```
STATUS CODE COUNT        421 200          <- zero non-200 responses
VERSION SERVED           239 v2 / 182 v1
update issued            15:31:59
first v2 response        15:32:09          (+10s)
UpdateStatus completed   15:34:03          (124s)
```

**Zero downtime, and the interleaving is the proof of *why*:**

```
15:32:08 200 v1 2760e9774730
15:32:08 200 v1 6abcecef9309
15:32:09 200 v2 bbf09df64247      <- first v2
15:32:09 200 v1 6e94b1ecd342      <- v1 still serving in the same second
15:32:10 200 v2 bbf09df64247
```

Both versions answer inside the same second, and the task counts confirm it
from the orchestrator's side — `5 v1 + 1 v2`, then `4 v1 + 2 v2`, and so on.
That is `order: start-first`: the replacement is brought to **healthy** before
the task it replaces is retired, so capacity never dips below five. Under the
default `stop-first` those moments would have had four tasks instead of five,
and any request in flight on the killed task would have failed.

The trade is real and worth stating: start-first needs spare capacity, because
the service temporarily runs `replicas + parallelism` tasks — six here.

**The timing is arithmetic, not luck.** `parallelism: 1`, `delay: 10s`, and a
task that takes ~15 s to pass its healthcheck gives 5 × ~25 s ≈ 125 s; measured
124 s. The first v2 appeared 10 s after the command because there was no image
pull to do — the layers were already on the node. On a multi-node swarm that
gap is the pull time and can dominate everything else.

`monitor: 20s` is what stops a task that lives for five seconds from counting
as a success, and `failure_action: rollback` is what task 38 exercises.

---

**Run 1 failed in an instructive way and is kept: `evidence/b4-task37-run1-versionbug.txt`.**

It produced **396 requests, all 200** — genuine zero downtime — but reported
`v1` for every single one, while `docker service ps` showed five v2 tasks. The
update had worked; the *reporting* had not.

Cause: `stack.yml` set `APP_VERSION: ${TAG:-v1}` in the service environment, so
the value `v1` was baked into the **service spec** at deploy time.
`docker service update --image …:v2` changes the image and nothing else, and a
container environment variable **overrides the image's own `ENV`**. Confirmed
directly rather than assumed:

```
$ docker service inspect abdur_notes_app --format '{{json .Spec…Env}}'
["APP_VERSION=v1","DATABASE_URL=…","PORT=3000"]
```

Fixed by removing `APP_VERSION` from the stack file and letting each image
carry its own (`ENV APP_VERSION=v1` / `v2` / `v3-broken`), then
`--env-rm APP_VERSION` on the live service. After that the same endpoint reports
the version that is actually running.

The general point is worth more than the bug: **a version indicator supplied by
deployment config rather than baked into the artifact will lie during exactly
the operation it exists to describe.** Had I only checked "did the responses
stay 200", run 1 would have passed this task while quietly proving nothing about
which code was serving. It is also a warning about `--image`-only updates in
general: anything else that drifted into the service spec — an env var, a
mount, a secret — survives an image roll untouched.

### Task 38 — Break v3 and roll back

`docker/Dockerfile.v3broken` sets `BREAK_HEALTHZ=1`, so `/healthz` returns 500.
The process starts perfectly and keeps running — it just answers wrongly. That
choice is deliberate: an image that *exits* would be caught by the restart
policy and would prove nothing about health checking.

`docker/b4-task38.sh` runs the experiment as a **controlled pair**, because the
brief's question ("what if there were no healthcheck?") is answerable by
measurement rather than assertion. Same broken image, same traffic loop, one
variable changed.

#### Phase A — v3 with the healthcheck (`evidence/b4-task38.txt`)

```
UpdateStatus.StartedAt     2026-09-04T13:37:34.504Z
UpdateStatus.CompletedAt   2026-09-04T13:38:07.955Z
UpdateStatus.State         rollback_completed
UpdateStatus.Message       rollback completed
final                      abdur_notes_app  5/5  notes-api:v2
clients during the deploy  124 requests  /  124 × 200  /  124 × v2
```

**Deploy to full rollback: 33.45 s.** The arithmetic: `parallelism: 1` means one
v3 task at a time, `monitor: 20s` is the window it must stay healthy through,
and `start_period: 10s` plus three 5-second retries is how long the healthcheck
takes to give up — the task never went healthy, `max_failure_ratio: 0` made one
failure enough, and `failure_action: rollback` reversed it.

**Clients saw nothing.** 124 responses, every one a 200 from v2. That is
`order: start-first` doing exactly what it exists for: the replacement is only
added to the routing mesh once it reports **healthy**, so a task that never
reaches healthy never receives a single request. The failure was contained to
the orchestrator; it never reached a user.

#### Phase B — the identical image with `--no-healthcheck`

Raw per-request log for this phase:
[`evidence/b4-task38-traffic.txt`](evidence/b4-task38-traffic.txt) — 327 lines,
one per request, which is where the counts below come from.

```
UpdateStatus.State         completed
UpdateStatus.Message       update completed
final                      abdur_notes_app  5/5  notes-api:v3
curl /healthz              500  {"status":"deliberately broken (v3)","version":"v3-broken"}
clients during the deploy  327 requests  /  184 × 500  /  135 × 200  /  8 × 000
```

**Swarm reported `update completed` for a service failing 59% of its requests**
(192 of 327 counting the 8 connection failures). No rollback, no warning, no
failed task — because from Swarm's point of view nothing failed.

The two numbers next to each other are the whole answer:

| | healthcheck | `--no-healthcheck` |
|---|---|---|
| Swarm's verdict | `rollback_completed` | `completed` |
| Time | 33 s | 103 s |
| Requests failed | **0 of 124** | **192 of 327** |
| Ended on | v2 (working) | v3 (broken) |

**The broken deploy took three times longer to "succeed" than the working
rollback took to fail.** Failing fast is a feature of having told the
orchestrator what "working" means.

#### The `Failed`/`Rejected` screenshot — and why it does not exist

The brief asks for `docker service ps` showing tasks in `Failed` or `Rejected`
state. **I did not capture one, because no task ever entered those states.** My
poll ran every 5 seconds through both phases and printed `failed/rejected: 0`
every time. Checking the task history afterwards
(`evidence/b4-task38-failed-tasks.txt`) confirms it rather than blaming the
sampling rate:

```
--- v3 task status ---
"State": "shutdown",  "Message": "shutdown",  "ContainerStatus": { "ExitCode": 0 }
```

**Exit code 0.** Even the deliberately broken containers terminated cleanly.
`Failed` means the container died; `Rejected` means a node refused to run it.
Neither describes what happened here — v3 started fine, ran fine, and answered
every request with a 500. Swarm shut the Phase A task down as part of the
rollback, which is a `shutdown`, not a failure.

That is the finding, not a gap in the evidence: **an application-level failure
does not produce a container-level failure state.** If I had gone looking for
`Failed` tasks as my signal that a deploy went wrong, I would have found none in
either phase — including the phase where 59% of requests were failing.
`UpdateStatus.State` and the healthcheck are what distinguished them.

(Phase A's rolled-back v3 task is no longer in the history above: it ran on slot
4 or 5, and the restoring `stack deploy` returned the service to `replicas: 3`,
removing those slots and their history with them. The three v3 entries shown are
Phase B's.)

#### The general lesson

Same as Scenario A task 15: **an orchestrator can only detect what you have told
it to measure.** A restart policy answers "is the process alive?"; only a
healthcheck answers "is it working?". Phase B is what "alive" alone buys you — a
green deployment, five healthy-looking replicas, and a 500 for every user.

One caveat on Phase A worth stating: the rollback was clean *because the
healthcheck was honest*. `/healthz` here is liveness-only — B2 task 26 showed it
reporting healthy for 3.0 s while the database was still initialising. A
healthcheck that lies passes the update, and Phase A becomes Phase B.

### Task 39 — Limits vs reservations

The brief asks for one impossible reservation. `docker/b4-task39.sh` asks for
the **same impossible number both ways**, because the interesting claim is not
"16G fails" — it is that limits and reservations are enforced by two different
pieces of software, at two different times, and therefore fail differently.

Node capacity, as Swarm sees it (`evidence/b4-task39.txt`):

```
host=vmi3536696  nanocpus=4000000000  membytes=8326938624
  schedulable memory = 7.76 GiB
```

#### Phase A — `--limit-memory 16G` on a 7.76 GiB node

```
state=completed
memory.max = 17179869184  (= 16.00 GiB)      <- read from inside the container
```

**Accepted without a murmur.** Docker set a 16 GiB cgroup ceiling on a machine
with 7.76 GiB of RAM, the update rolled out normally, and the service kept
serving. A limit is never compared against the node's capacity, because it is
not a claim on anything — it is a ceiling, and a ceiling above the roof is
merely useless.

#### Phase B — `--reserve-memory 16G`, identical number

```
ID            NAME                NODE         DESIRED   CURRENT    ERROR
pnlkizm2x1df  abdur_notes_app.3   (empty)      Running   Pending    "no suitable node (insufficient resources on 1 node)"

Status: { "State": "pending",
          "Message": "pending task scheduling",
          "Err": "no suitable node (insufficient resources on 1 node)" }
DesiredState "running"   NodeID ""

UpdateStatus: { "State": "updating", "Message": "update in progress" }
```

Three details in there are the whole answer:

1. **`NodeID` is empty, and `docker node ps self` does not list the task.** It
   was never assigned to a machine. Nothing was started and nothing was killed.
2. **`DesiredState` is `Running`, `CurrentState` is `Pending`** — Swarm still
   intends to run it and is waiting for a node that will never appear.
3. **`UpdateStatus.State` stayed `updating`.** Not `paused`, not `rollback` —
   `failure_action: rollback` never fires, because from Swarm's point of view
   nothing has failed yet. Phase A completed in 80 s and the undo in 64 s; this
   one would have sat there indefinitely.

#### The difference

- A **limit** is a runtime ceiling enforced by the kernel through cgroups. The
  container physically cannot exceed it: past the memory limit the OOM killer
  ends it (exit 137, B2 task 28a); past the CPU limit it is throttled. A limit
  protects *other* workloads from this container.
- A **reservation** is a *scheduling* promise and nothing else. Swarm places the
  task only on a node with that much unclaimed capacity and subtracts it from
  that node's pool for future decisions. It hands the container no memory, does
  not guarantee the memory will be free later, and constrains the running
  process in no way at all. A reservation protects *this* container from being
  scheduled where it cannot fit.

`Pending` versus `OOMKilled` is the fastest way to tell which one you actually
configured.

#### Two things worth adding

**Reservations are bookkeeping, not measurement.** During this run `free -g`
reported ~5 GiB actually available while Swarm called 7.76 GiB schedulable — it
never looked at real usage. It only sums the reservations it has already
granted. So a cluster of services that all reserve `128M` while each really
using 2 GiB will be scheduled cheerfully onto one node, and then die of OOM with
Swarm insisting there is plenty of room. Reservations are only as honest as the
numbers you put in them.

**A stuck deploy is not a broken service.** The traffic loop ran through both
phases: **164 requests, all 200, zero failures.** With `order: start-first` the
old task is retired only after the replacement is healthy — and a replacement
that is never even placed can never trigger that retirement. This is the
"service will not start and there is no error" failure mode: the symptom is not
an outage, it is a deployment that silently never finishes. `UpdateStatus.State`
is the only place it shows, which is why it belongs in a deploy script's exit
check and not just in a human's terminal.

**One caveat, honestly.** The first run of `b4-task39.sh` did not capture the
Pending task at all: `head -6` on the `service ps` output was consumed by old
`Shutdown` entries, and I had filtered on `--filter desired-state=ready`, which
was simply a wrong guess — a Pending task's desired state is `Running`, as the
output above shows. The re-run (`docker/b4-task39b.sh`,
`evidence/b4-task39b.txt`) drops both the filter and the truncation. The lesson
is the same one as B3's grep failures: a filter that returns nothing looks
exactly like a system that did nothing.

### Task 40 — Scale down under traffic

Counting failures alone would not have explained anything, so the client is
split the same way as task 36, because task 36 established the fact that makes
scale-down interesting: **the routing mesh balances per connection, not per
request.** That predicts two different experiences of the same event.

- **Client A** — `Connection: close`, a fresh TCP connection per request. The
  mesh re-picks a task every time, so it should never be handed one that is
  going away.
- **Client B** — one `curl` process, **one socket**, 400 requests at 10/s. This
  client is pinned to a single task. If that task is one of the three being
  removed, it is holding a socket to a process that is shutting down.

**Result across both runs: 2116 requests, 2116 × 200, zero failures.**

#### Client A — `evidence/b4-task40.txt`

```
916 requests   916 × 200   0 failures
scale issued   16:08:00.767
converged      16:08:11.812      (11.0s)
```

The first request after the scale command landed at `16:08:00.833`, 66 ms later,
and returned 200. There is no gap anywhere in the log.

#### Client B — `evidence/b4-task40b.txt`, three pinned sockets

| client | pinned to | removed? | socket change | ended on | failures |
|---|---|---|---|---|---|
| 1 | `1525c547e379` (task .5) | **yes** | 138 → `conn=1` → 262 | `014fff66f2fa` (.1) | 0 |
| 2 | `d009642fa4c9` (task .4) | **yes** | 150 → `conn=1` → 250 | `5adf2c7cad10` (.2) | 0 |
| 3 | `5adf2c7cad10` (task .2) | no | **never** — `conn=1` once, the initial connect | same | 0 |

Two of the three sockets were pinned to a task that was about to be deleted, and
**both migrated to a survivor without losing a single request.** Client 3 is the
control that makes the other two mean something: a client whose task survived
never reconnected at all, across 400 requests on one socket. So the reconnects
in clients 1 and 2 were caused by the scale-down and by nothing else.

The timing lines up to within a second. Client 1's 138th request lands at
≈ `16:12:32.4` and client 2's 150th at ≈ `16:12:33.6`, against a scale command
at `16:12:33.809`.

**The mechanism:** `server.close()` (`app/src/server.js:298`) stops accepting new
connections but lets in-flight requests finish, and Node then marks its
responses `Connection: close`, which is what forces the pinned client to open a
fresh connection — and the fresh connection goes through the mesh, which now
only knows about survivors. The client never sees the transition as an error
because the last response on the dying socket is a normal 200.

#### Was the SIGTERM handler actually the reason?

Two independent pieces of evidence, because the first one is only circumstantial.

**Circumstantial — the drain was far too fast to be a timeout.**
`stop_grace_period: 30s`, but the containers were gone in ~8 s (run 2) and ~11 s
(run 3). B2 task 28 established that **the kernel applies no default signal
action to PID 1**: an unhandled SIGTERM to a PID-1 process does nothing at all.
So had nothing been listening, every container would have sat there for the full
30 seconds and then been SIGKILLed. Exiting early is only possible if something
handled the signal.

**Direct — the log line, caught live (`evidence/b4-task40c.txt`):**

```
abdur_notes_app.3.uxan6k86w5bc | {"level":"info","msg":"shutting down","signal":"SIGTERM"}
```

#### Three things that went wrong on the way, and what they cost

**1. The first Client B did not test what I claimed it tested.** It ran 40
requests per `curl` process and looped — a new process each second, therefore a
new socket each second (`conn=0: 1248, conn=1: 32`, exactly one connect per
batch). The socket only ever lived ~1 s, so it could not have straddled the
scale-down. The re-run with a single long-lived `curl --rate 10/s` is the one
that answers the question.

**2. `-o /dev/null` only applies to the first URL.** With 40 URLs and one `-o`,
curl wrote 39 response bodies to stdout, which concatenated with `-w` output into
lines like `{"status":"ok",...}200`. My "non-200" report then listed lines that
were all, in fact, 200s. The parse was broken, not the service.

**3. The stopped/running detection was inverted.** `while read -r _ cid name`
against a list with leading spaces put the *name* into `$cid`, so the `docker ps`
membership test never matched and all five containers were reported STOPPED —
and the two whose logs printed were the two **survivors**. Every field in that
section was wrong while looking entirely plausible.

All three are the same failure: **a measurement that returns something is not the
same as a measurement that is measuring the right thing.** Client 3 exists
precisely because a control makes that detectable.

#### Two operational findings the brief did not ask for

**Scaling down is an order of magnitude faster than scaling up.** 11 s here
against 124 s for the rolling update in task 37 — because removing a task waits
for nothing, while adding one waits for a healthcheck. This asymmetry is why a
service under a traffic spike sheds capacity instantly and regains it slowly.

**A scaled-down task's container is deleted immediately.** The follow-up tried
`docker logs`/`docker inspect` on the three removed containers and got
`No such container` for all three — there is no post-mortem to do on the host.
Anything you need from a task that goes away has to have been shipped off the
box before it went. That is also why the log line above had to be captured with
`docker service logs --follow` started *before* the scale command.

**And a smaller trap worth recording.** `docker service logs --since 15m | grep
'shutting down'` returned nothing, which looked like "the handler never ran". The
real cause was leftover state from task 39:

```
error from daemon in stream: ... task pnlkizm2x1df... has not been scheduled
```

The Pending tasks from the 16G reservation experiment made the daemon abort the
whole log stream after 4 lines. The grep was not reporting on the service at all.
Checking `wc -l` before trusting a `grep` is the same discipline B3 forced three
times over.

---

## B5 — CI/CD

### Task 41 — The PR pipeline

[`.github/workflows/pr.yml`](../.github/workflows/pr.yml). Checkout → 10 tests
against a real Postgres service container → build → **run the image and curl
`/healthz`** → assert non-root and no `.env` in the image.

**PR #1: <https://github.com/rasel-xs/devops-exam/pull/1>**

| | Run | Result |
| --- | --- | --- |
| Failing | [33884146208](https://github.com/rasel-xs/devops-exam/actions/runs/33884146208) | `test` **failure** in 21s, `build-and-smoke` **skipped** in 0s |
| Passing | [33884321458](https://github.com/rasel-xs/devops-exam/actions/runs/33884321458) | both green; GitHub reports **51s**, of which 45s is the two jobs (22s + 23s) and the rest is queueing between them |

Screenshots: `evidence/b5-pr-failed.png`, `evidence/b5-pr-passed.png`. Full log
extract: `evidence/b5-pr-failed.txt`.

#### The bug the PR was built around

Rather than break something arbitrary, PR #1 introduces the failure that matters
most in a multi-tenant application — and introduces it the way it actually
happens. The change removes the `tenant_id` predicate from `GET /api/notes/:id`:

```diff
-      'SELECT * FROM notes WHERE id = $1 AND tenant_id = $2',
-      [req.params.id, req.tenantId]);
+      // id is the primary key, so the tenant_id condition is redundant.
+      'SELECT * FROM notes WHERE id = $1',
+      [req.params.id]);
```

The commit message's reasoning is the kind that survives code review: `id` *is*
unique, so the query does return exactly one row either way. What it stops doing
is checking **whose** row it is. `GET /api/notes/<id>` with any `X-Tenant` header
now returns another tenant's note.

```
not ok 3 - a note created by one tenant is invisible to another
    cross-tenant read returned data
  expected: 404
  actual: 200
# tests 10   # pass 9   # fail 1
```

#### Three things this run demonstrates that a green tick alone would not

**1. Nine of ten tests passed.** The suite was not broadly red — a single
assertion stood between this and a production data leak. That is the argument
for the cross-tenant test existing at all, and for it asserting a **404** rather
than checking a response shape.

**2. One test on the very same endpoint did not catch it.** `GET /api/notes/:id
returns 404 for an id that does not exist` passed, because a nonexistent id
yields zero rows with or without the predicate. Same route, same bug, silent.
Test coverage of an endpoint is not the same as coverage of its *security
property*, and a coverage percentage would have reported both tests as equal
value.

**3. `build-and-smoke` ran for 0 seconds.** `needs: test` gated it, so the
broken code was never built, never containerised, and could not have reached a
registry or a deploy job even in principle. This is the same ordering argument
that task 45 relies on, observed here rather than asserted.

#### Why a real database instead of a mock

This bug is *entirely* in SQL. A mocked `db.query` returns whatever the test
author told it to return, so the mock would have reported the same rows before
and after the change and every test would have passed. The class of bug that
most threatens this application is invisible to the testing style that would be
faster and easier to set up. The Postgres service container is health-gated with
`pg_isready` for the reason B2 task 26 measured directly: without it the job
races `initdb` and fails intermittently, which is worse than failing always.

#### Why the smoke step earns its place

An image can build perfectly and still be unable to start: a typo in `CMD`, a
runtime file excluded by `.dockerignore`, a native module built against the
wrong libc. Only running it finds that. It polls for up to 30s rather than
`sleep 10 && curl`, because a fixed sleep is either flaky or slow and usually
both. It is deliberately given a **bogus** `DATABASE_URL`, which works precisely
because `/healthz` is a liveness probe that does not touch the database — the
distinction B2 task 26 established. A smoke test pointed at `/readyz` would need
a database and would be testing something else.

The non-root and no-`.env` assertions turn B1 tasks 21 and 25 from a one-off
screenshot into a check that runs on every pull request.

### Task 42 — Caching

Two independent caches: `actions/setup-node` with `cache: 'npm'` keyed on the
lockfile hash, and `type=gha` for Docker layers via Buildx.

#### The measurement

The first attempt at this was wrong and is worth recording, because it would
have produced a confident number from a contaminated experiment. PR #1's second
run looked like a cold Docker build — it was the first `build-and-smoke` this
branch had ever completed — but its log said `importing cache manifest` and
showed nine `CACHED` layers, and the build finished in 9s. The cache had been
populated by `deploy.yml`, which has been running on **every push to `main`
since 2 September** with `cache-to: type=gha,mode=max`. Nothing about the branch
looked warm; the cache is shared across the repository.

So the real measurement deletes the cache first, and holds the code fixed:

- `gh cache delete --all` — 60 entries, ~440 MiB of buildkit blobs
- two `git commit --allow-empty` pushes, so the tree is **byte-identical**
  between the two runs and the only variable is cache presence

| | Cold | Warm | Change |
| --- | ---: | ---: | ---: |
| **Whole run** | **136s** | **71s** | **−48%** |
| `test` job | 27s | 34s | **+26%** |
|   ↳ Install dependencies | 2s | 1s | −50% |
| `build-and-smoke` job | 106s | 34s | −68% |
|   ↳ **Build the image** | **83s** | **12s** | **−86%** |

Cold run [33884738905](https://github.com/rasel-xs/devops-exam/actions/runs/33884738905),
warm run [33885130382](https://github.com/rasel-xs/devops-exam/actions/runs/33885130382).
Log extract: `evidence/b5-cache.txt`.

#### The test job got *slower*, and that is the more useful result

The npm cache verifiably worked:

```
Cache hit for: node-cache-Linux-x64-npm-f71aae76…
added 86 packages, and audited 87 packages in 408ms     (warm)
added 86 packages, and audited 87 packages in 1s        (cold)
```

It saved about 600 ms. The job still took 7 seconds **longer**, because
`Initialize containers` — pulling `postgres:16-alpine` — took 20s warm against
13s cold. That is runner-to-runner variance, and it is an order of magnitude
larger than the thing being optimised.

Two things follow, and both matter more than the headline percentage:

1. **A single before/after pair cannot prove a small improvement.** The npm
   cache is real and measurable in its own step, and completely invisible at job
   level. Had I only reported the job totals, the honest reading of this data is
   "npm caching made CI slower", which is false.
2. **Cache where the work is.** 86 packages is nothing. The expensive thing is
   the Docker build — a Debian base image, `npm ci` inside a layer, and a second
   Alpine stage — and that is exactly where the 71 seconds came from.

The largest remaining cost in the `test` job is the Postgres image pull, and
**no cache setting in this workflow addresses it**, because service-container
images are pulled by the runner before any step executes. Adding more `cache:`
keys would not touch it.

#### Scope, and the trap in it

GitHub's cache is scoped per branch, with read-only access to the default
branch's cache. A PR therefore warms from `main` but cannot write back, so the
first run on a new dependency set is always cold — and, as the contaminated
measurement above shows, a branch can be warm on its very first build because of
work `main` did days earlier. "First run on this branch" is not a synonym for
"cold cache", and assuming it is produces a number that looks fine and means
nothing.

### Task 43 — The main pipeline

[`.github/workflows/deploy.yml`](../.github/workflows/deploy.yml). Builds,
tags, pushes to GHCR, then deploys behind the task 44 gate.

**Green run: [33903125661](https://github.com/rasel-xs/devops-exam/actions/runs/33903125661)**
— `build-and-push` 1m17s, `deploy` 1m46s, 3m22s end to end.
Evidence: `evidence/b5-deploy-green.txt`.

```
building v1.0.69 from b4e7dfc
ghcr.io/rasel-xs/notes-api:v1.0.69
ghcr.io/rasel-xs/notes-api:sha-b4e7dfc59f31b5b32ca74c2b454c59f1b99d407c
ghcr.io/rasel-xs/notes-api:latest
```

Package page: `evidence/b5-ghcr-tags.png`.

**Three tags, three different jobs.** `v1.0.<commit-count>` is ordered and
readable, so "which release is older" is answerable at a glance. The full SHA
tag is unambiguous — it names the commit that produced this exact artefact, and
it is the tag I would use to answer "what is actually running?" during an
incident. `latest` exists only on the default branch and is a convenience, never
a deploy target: B4 task 38's rollback works because the previous version is a
specific artefact still in the registry, which is exactly what `latest` is not.

**No long-lived credentials.** GHCR auth is `${{ github.token }}`, minted per run
and expired when the job ends. There is no `AWS_SECRET_ACCESS_KEY` and no static
access key anywhere in this repository; the OIDC pattern Scenario C uses is
included commented at the bottom of the file.

The SSH deploy key **is** a long-lived secret and I am not pretending otherwise.
What limits it is in task 44 below, and it is tested rather than asserted.

**Multi-arch (`linux/amd64,linux/arm64`).** The VPS is amd64 and my laptop is an
arm64 Mac: an amd64-only image runs on the Mac under emulation, and an
arm64-only image does not run on the VPS at all — it fails with
`exec format error`, which reads like a corrupt binary rather than an
architecture mismatch. The cost is roughly double the build time, since the
non-native architecture builds under QEMU.

**`APP_VERSION` is a build arg, not a constant.** This was wrong for the first
three CI deploys and is written up in task 44; the short version is that B4 task
37 established "bake the version into the artefact, never into deploy config",
and this pipeline obeyed the letter of that while baking in a **fixed** string,
so every image reported `v1` regardless of its tag.

### Task 44 — The approval gate

`environment: production` with a required reviewer, created through the
Environments API rather than by hand so the configuration is reproducible.

```
run 33903125661 approvals:
  state: approved
  by: rasel-xs
  environments: production
```

- Paused with "Review pending deployments": `evidence/b5-approval-pending.png`
- After approval: `evidence/b5-approval-approved.png`
- Machine-readable capture of the paused state: `evidence/b5-approval-pending.txt`
- New tag live on the VPS: `evidence/b5-vps-new-version.png`

**The gate is a secret boundary, not just a pause.** All four VPS secrets
(`VPS_SSH_KEY`, `VPS_KNOWN_HOSTS`, `VPS_HOST`, `VPS_USER`) are scoped to the
`production` environment, not to the repository. `gh secret list` at repository
level returns none of them. A job that has not passed the gate cannot read the
deploy key at all — so a workflow change that tries to exfiltrate it has to get
a human to approve the deployment first.

#### The deploy key cannot open a shell

The claim "restricted to one command" is worth nothing unless it is tested, so
it was (`evidence/b5-deploykey-restriction.txt`):

```
authorized_keys:
  command="/root/abdur-deploy.sh",no-port-forwarding,no-agent-forwarding,
  no-X11-forwarding,no-pty,no-user-rc ssh-ed25519 AAAA... github-actions-abdur-deploy

whoami                   -> refused: this key may only run 'deploy <tag>', 'status' or 'health'
cat /etc/shadow          -> refused
(no command / shell)     -> refused
deploy v9.9.9-evil       -> refused: tag is not v1.0.<n> or sha-<hex>
deploy ../../etc/passwd  -> refused
deploy 1.0.0; id         -> refused          <- the '; id' never ran
status                   -> exit 0
```

The VPS is shared and the account is root, so an unrestricted key in a repository
secret would mean: anyone who can change a workflow, or read the secret through
a compromised marketplace action, gets root on a machine that is not only mine.
The forced command does not make the key harmless — it changes the blast radius
from "root shell" to "can deploy a tag that already exists in my registry". That
is the honest claim.

`no-pty` and `no-port-forwarding` matter separately from the forced command:
without them the key could still be used to tunnel to other students' services
on the box. `no-user-rc` closes `~/.ssh/rc` as a way around the forced command.

The workflow uses plain `ssh` rather than a marketplace action, because an action
that receives the private key is one more supply-chain hop for the most sensitive
secret in the repository and buys nothing here — the whole remote side is one
forced command taking one argument. Host key pinned from a secret with
`StrictHostKeyChecking=yes`; neither `no` nor `accept-new`, both of which hand
the key to whoever answers port 22 first.

#### What the successful deploy looked like

```
deploying ghcr.io/rasel-xs/notes-api:v1.0.69 to abdur_notes_app
  [1]  state=updating   replicas=3/3  tasks_on_v1.0.69=1/3
  [4]  state=updating   replicas=4/3  tasks_on_v1.0.69=1/3     <- start-first: 4 tasks for 3 replicas
  [10] state=updating   replicas=3/3  tasks_on_v1.0.69=3/3
  [17] state=completed  replicas=3/3  tasks_on_v1.0.69=3/3
  health poll 1/30
live and healthy: {"status":"ok","version":"v1.0.69","host":"b47949a4d83d"}
...then from the runner, over the public internet:
                  {"status":"ok","version":"v1.0.69","host":"8407754bfd5b"}
deployed version was v1.0.69
```

The two health responses come from **different containers** — the routing mesh
picked a different replica for the external check. That is stronger evidence
than one container answering twice: it shows more than one replica is on the new
version and reachable from outside the host.

The `replicas=4/3` samples are `order: start-first` with `parallelism: 1`
creating the replacement before retiring the task it replaces, the same
behaviour measured in B4 task 37.

#### Five bugs, each hidden behind the last

The first CI deploy succeeded and the pipeline called it a failure. The second
succeeded and the pipeline hung. This is the record of what was actually wrong,
because none of it was visible until the defect in front of it was cleared.

**1 — No SSH keepalive.** Run #9 updated all three replicas, then died with
`client_loop: send disconnect: Broken pipe`, exit 255, during a quiet minute in
the remote health loop. The deploy had worked; the transport had not.
Fixed with `ServerAliveInterval=15`.

**2 — `docker service update` never converged.** Run #10 printed
`overall progress: 0 out of 3 tasks` for over eight minutes, while
`UpdateStatus` said `completed` after **93 seconds** and all three tasks were
healthy on the new image. The cause was a leftover task from the task 39
reservation experiment with an **empty `NodeID`** — the progress writer resolves
tasks to node names and never can for that one, so the slot is never marked
done. The same ghost had already broken `docker service logs` in B4 task 40. It
has since aged out of task history on its own; `--detach` plus an explicit poll
stays, because the next ghost costs another eight minutes.

**3 — `APP_VERSION` was a constant.** Every CI image carried tag `v1.0.<n>` and
answered `"version":"v1"` from `/healthz`. This is the *other half* of the B4
task 37 bug. There, the fix was "bake the version into the artefact rather than
supplying it from deploy config" — and this pipeline did exactly that, while
baking in a fixed string. **The dangerous property of this one is that it raises
no red light at all**: the deploy is green, `/healthz` returns 200, and the only
symptom is that the endpoint whose job is to answer "which code is running?"
answers the same thing forever. Now `ARG APP_VERSION` with the CI passing the
version it derived.

**4 — `curl` with no timeout against `localhost`.** Run #11 sat on
`health poll 1/30` for eight minutes and **never printed poll 2** — so curl
blocked on the first call rather than being slow, which is what distinguishes a
hang from a delay. `localhost` resolves to `::1` first and the published port is
IPv4. B2 task 28 measured the underlying behaviour directly: a dropped packet
produces no RST, so the client waits out the full TCP timeout instead of failing
fast. Every B4 script used `127.0.0.1` with `--max-time` for that reason; this
script had drifted off it.

**5 — A bare `{{.UpdateStatus.State}}` template.** It fails with
`map has no entry for key "UpdateStatus"` when the field is **absent** — which it
is on a service that has never been updated, and after a no-op update. CI never
hits this, because every run carries a fresh tag. Re-running the same tag by
hand does, which is how it surfaced.

**The convergence check that came out of this is deliberately ordered:**

1. **Rollback first.** It is the one failure that task-counting cannot see —
   the tasks return to the old image and the count simply never rises.
2. **Then the task count**, which is the authority. This comes straight from B4
   task 38 phase B, where Swarm reported `update completed` for a service
   answering 500 to every request.
3. **`UpdateStatus` last**, and only to separate "nothing to do" from "done".

#### The method lesson, stated plainly

Four of these five were found by pushing to CI and waiting — five to fifteen
minutes each, plus a build, a queue and an approval every time. The fifth was
found in seconds by running the same script by hand over SSH, which is what I
should have done first. **A deploy script is the slowest possible thing to debug
from inside CI**, and it is usually runnable directly. The final version was
verified by hand before being pushed: `deploy v1.0.68` gave exit 0 and
`{"version":"v1.0.68"}`, `deploy v9.9.9` gave exit 1.

There is a second, less comfortable lesson. Twice the pipeline reported failure
while production was healthy and correctly updated. B4 task 38 showed the
opposite — a tool reporting success over a service returning 500s. Both
directions have the same moral: **a pipeline's verdict is a statement about the
pipeline.** The only thing that settles what is running in production is asking
production, which is why the last step of this deploy queries the service from
outside the host rather than trusting the exit code of the step before it.

### Task 45 — Break it three ways

Each failure is placed one stage later than the last, so the answer to "where
does this get caught?" is different every time.

| # | How | Caught in | Run |
| --- | --- | --- | --- |
| 1 | Inverted an assertion in `tests/api.test.js` | `test` | [33903850193](https://github.com/rasel-xs/devops-exam/actions/runs/33903850193) |
| 2 | `COPY nonexistent-file` in the Dockerfile | `build-and-smoke` | [33903962353](https://github.com/rasel-xs/devops-exam/actions/runs/33903962353) |
| 3 | Deployed a tag that was never built | `deploy`, on `main` | [33904509040](https://github.com/rasel-xs/devops-exam/actions/runs/33904509040) |

PR: <https://github.com/rasel-xs/devops-exam/pull/2>.
Screenshot of the failed deploy: `evidence/b5-deploy-failed.png`.

**Failure 1 — the test job.**

```
not ok 3 - GET /api/notes/:id returns 404 for an id that does not exist
  expected: 200
  actual: 404
# tests 10   # pass 9   # fail 1
test: failure     build-and-smoke: skipped
```

**Failure 2 — the build job, and the point is that job 1 was green.**

```
test: success                      <- all 10 tests passed
build-and-smoke: failure
ERROR: failed to compute cache key: "/nonexistent-file": not found
```

A test suite cannot see a Dockerfile. `npm test` runs against the source tree
and never builds an image, so a packaging error passes every test and still
produces nothing runnable. That is the whole argument for the build-and-smoke
job existing separately, and failure 2 is what it looks like when it earns its
place.

#### Failure 3 — and a change to my own plan

My draft answer said "point the deploy step at a wrong service name". I changed
it, because that failure is worthless as evidence: `docker service update` on a
name that does not exist errors immediately without touching anything, so
"production survived" would have been true in the way that standing still is
true. It tests nothing.

Deploying **a well-formed tag that was never built** is the version that
actually asks the question. `v1.0.99999` passes the server-side allow-list
because it is shaped exactly like a real version, so the request is accepted and
Swarm genuinely begins a rollout against production.

```
deploying ghcr.io/rasel-xs/notes-api:v1.0.99999 to abdur_notes_app
--- waiting for convergence ---
  [1] state=updating          replicas=3/3  tasks_on_v1.0.99999=1/3
ERROR: the update did not succeed -- state=rollback_started
  [2] state=rollback_started  replicas=3/3  tasks_on_v1.0.99999=0/3

27cck7ew47c89ly2thzrgh5vw  \_ abdur_notes_app.3  notes-api:v1.0.99999
    Shutdown   Rejected 5 seconds ago
    "failed to resolve reference "ghcr.io/rasel-xs/notes-api:v1.0.99999": not found"

Error: Process completed with exit code 1.
Verify the new version answers from the internet: skipped
```

**Failed in 17 seconds**, against the 33 seconds B4 task 38 measured — because a
missing image fails at pull time, while a broken healthcheck has to wait out
`start_period` plus retries plus `monitor`.

**This also produced the artefact B4 task 38 could not.** That task's brief asked
for `docker service ps` showing a task in `Failed` or `Rejected` state, and I had
to write that no such state ever existed: the v3 image *started fine and answered
wrongly*, so every container exited 0 and Swarm recorded `shutdown`. Here the
image does not exist at all, so the task genuinely is **`Rejected`**, with the
registry's error attached. The two runs together make the point better than
either alone: **an application-level failure produces no container-level failure
state, and only an infrastructure-level one does.**

#### Production survived — the number that proves it

`evidence/b5-prod-survived.txt`, recorded before and after:

```
BEFORE 18:09:41Z   {"version":"v1.0.69"}   3 tasks Running 11-12 minutes
AFTER  18:22:16Z   {"version":"v1.0.69"}   3 tasks Running 24-25 minutes
```

**The uptime is the evidence.** Those containers are 24 and 25 minutes old,
which means they predate the bad deploy by more than twenty minutes and were
never restarted, never replaced, never even briefly removed from the mesh. Five
consecutive requests from the public internet returned 200 from three different
containers, all still on `v1.0.69`. The entire cost of the failed deploy was one
`Rejected` task in the service's history.

#### What made the failed deploy safe

1. **`docker service update` is a rolling in-place update, not delete-and-
   recreate.** At no point does a working version stop running.
2. **`--update-failure-action rollback` with a healthcheck.** Here the task never
   started at all, so rollback fired on the pull failure — 17s from request to
   `rollback_started`.
3. **`start-first` ordering.** The replacement must be healthy before the task it
   replaces is retired. `tasks_on_v1.0.99999` never got past 1, and `replicas`
   never dropped below `3/3`.
4. **Cheap checks fail first.** Failures 1 and 2 never reached the deploy job at
   all — `needs:` means a red build cannot deploy, so two of the three could not
   have touched production even in principle.
5. **Immutable, uniquely-tagged images.** "The previous version" is `v1.0.69`, a
   specific artefact still in the registry, not whatever `latest` happens to
   point at.

#### What `docker service rm` + recreate would have done instead

The service is deleted first, so the site is down from that moment — before
anything has gone wrong, and for the whole length of the deploy rather than the
moment of failure. Then the recreate fails on the same missing tag, and there is
**nothing running at all** and no automatic path back: `--rollback` restores a
service's *previous spec*, and a deleted service has no spec to restore. Recovery
becomes a human at a shell, under pressure, reconstructing a `service create`
command from memory.

Applied to what actually happened: the same 17 seconds would have been a
permanent outage instead of a log line.

That is the general principle — deploys should be **additive then cut over**, not
**destructive then rebuild**. Same idea as blue/green, and the same reason
`start-first` exists.

### Task 46 — The safeguard

I added both.

**Concurrency group.** `deploy-main` with `cancel-in-progress: false`. The
incident it prevents: two commits merged 30 seconds apart, two deploy jobs
running simultaneously, both calling `docker service update` on the same
service. Swarm processes the second update while the first rollout is
mid-flight, so tasks end up on a mix of images, `UpdateStatus` becomes
`paused`/`rollback_started` from interleaved instructions, and the version that
ends up live is whichever job's API call landed last — **not** necessarily the
newer commit. You then have production running code that no green tick
corresponds to. Queueing serialises them so each rollout completes before the
next begins.

**Observed, not just argued.** Two pushes to `main` landed 110 seconds apart
while finishing this scenario, and the group caught them
(`evidence/b5-concurrency.txt`):

```
33905896621  status=pending   created=18:26:28   "restore the task 43 and 44 answers"
33905733598  status=waiting   created=18:24:38   "revert failure 3"
```

The older run is `waiting` — held at the task 44 approval gate — and it is
still holding the concurrency group, so the newer one is `pending` and has not
started. Without `cancel-in-progress: false` both would have proceeded and
issued `docker service update` against `abdur_notes_app` concurrently, which is
precisely the incident described above. Note also *which* one is queued: the
**newer** commit is the one waiting, so if these had raced, the version left
running could easily have been the older one.

**And a limitation of the safeguard, found the same way.** `cancel-in-progress:
false` protects the run that is *executing*; it does not give you a queue.
GitHub keeps at most **one** pending run per concurrency group, so a newer push
cancels the one waiting behind the gate. Five pushes to `main` in quick
succession produced exactly that:

```
33907618929  pending                <- newest, queued
33906838041  completed/cancelled
33906171234  completed/cancelled    <- each superseded by the next
33905896621  completed/cancelled
33905733598  waiting                <- holding the group at the approval gate
```

Nothing here was harmful — every cancelled run had already pushed its image, and
only the deploy was skipped — but it is worth stating plainly rather than
implying the group queues everything. If each commit genuinely had to reach
production, `concurrency` alone would not deliver that; the deploy would need to
be idempotent and driven from the current `main` rather than from the commit
that triggered it. For this exam the behaviour is correct: the newest commit is
what should go out, and the intermediate ones are exactly what you want dropped.

Note the deliberate asymmetry: the PR workflow uses `cancel-in-progress: true`,
because superseding a build wastes nothing, while cancelling a half-finished
deploy leaves the service mid-rollout — the exact state the group exists to
prevent.

**Job timeouts.** `timeout-minutes: 15` on every job. GitHub's default is **6
hours**. The incident: a test that waits on a database that never becomes ready
hangs, holding a runner for six hours, blocking every other job on a
concurrency-limited plan and burning the minutes budget — and because the job
never *fails*, nobody is notified. A 15-minute timeout converts a silent stall
into a visible failure.
