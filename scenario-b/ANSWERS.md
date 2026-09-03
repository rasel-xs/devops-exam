# Scenario B — Answers

**Exam token:** `root-vmi3536696-1788282556-1536d427`
**Server:** `169.58.246.108` — Ubuntu 24.04.4, Docker 29.7.2, Compose v5.5.0

> **Shared machine.** This VPS also hosts other students, and one of them
> already runs containers named `notes-api` / `notes-db` with a
> `docker_notes-db-data` volume. Everything here is namespaced: compose project
> `abdur-notes`, image `abdur/notes-api`, host ports 3120 (app), 3130 (Grafana),
> 9190 (Prometheus), 5433 (Postgres), 3140 (Swarm), stack `abdur_notes`.
>
> `<<FILL: ...>>` marks a number not yet measured.

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
| devDependencies (`--omit=dev`) | `<<FILL>>` | Cannot run the test suite inside the production image. Tests run in CI against the source, so nothing lost. |
| `npm cache clean --force` | ~50 MB | Nothing. It is a download cache for a machine that will never install again. |
| npm, npx, yarn (removed explicitly) | see note | Cannot install anything at runtime — which is the entire point. Note this removal does **not** shrink the image: see task 25. |
| `vim`, `curl` | ~30 MB | Debugging inside the container is harder — no shell tooling to poke around with. Mitigation is `docker debug` / an ephemeral sidecar sharing the namespace, not shipping an editor to production. |

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

`docker/docker-compose.broken-depends.yml` on a fresh volume:

```
app-1  | Error: connect ECONNREFUSED 172.19.0.2:5432
app-1 exited with code 1
```

`depends_on` is an ordering constraint on *container* lifecycle, not on
readiness. Compose starts postgres's container, sees it running, and starts the
app immediately. Meanwhile Postgres has to `initdb`, create the role and
database, and restart its internal server — several seconds during which the
port is either closed or answering only on a private unix socket.

The trap: on the *second* run it usually works, because the volume is already
initialised and Postgres is up in under a second. So this bug passes on your
laptop and fails on a cold deploy or in CI — exactly the class of bug that is
worst to have.

**The fix** (`docker/docker-compose.yml`), two independent layers:

```yaml
depends_on:
  postgres:
    condition: service_healthy
```

plus a healthcheck on postgres, plus a retry loop in `db/migrate.js`. Two
subtleties:

- The healthcheck is `pg_isready -U notes -d notes -h 127.0.0.1`, not a bare
  `pg_isready`. During initdb Postgres runs a **temporary** server on a unix
  socket to bootstrap; a bare `pg_isready` happily reports "accepting
  connections" against that one, and the gate opens too early.
- The app-side retry is not redundant. Compose's `condition:` does not exist in
  Swarm at all (B4 has no `depends_on`), and databases restart while
  applications are running. An app that cannot survive its database going away
  for 10 seconds is broken regardless of what starts it.

### Task 27 — Volumes and persistence

| Step | Result |
| --- | --- |
| Create notes, `docker compose down`, `up -d` | notes still there — `<<FILL: count>>` |
| `docker compose down -v`, `up -d` | notes gone — count is 0 |

**What `-v` did.** `docker compose down` removes containers and networks and
leaves named volumes alone — that is why the data survived. `-v` additionally
removes the named volumes declared in the compose file, so `pgdata` — the actual
Postgres data directory — is deleted. The next `up` creates a brand new empty
volume and Postgres initdbs into it from scratch. There is no undo and no
prompt. `down -v` is the single most dangerous routine Docker command, and it is
one keystroke away from `down`.

Related trap worth knowing: `-v` only removes volumes *declared in the compose
file*. Anonymous volumes created by the image survive, which is why databases
sometimes appear to keep old data even after `down -v`.

**Recovery** — [`docker/backup-restore.sh`](docker/backup-restore.sh):

```bash
bash docker/backup-restore.sh backup            # pg_dump | gzip -> ./backups/
docker compose down -v && docker compose up -d  # data destroyed
bash docker/backup-restore.sh restore backups/notes-<ts>.sql.gz
```

Counts before and after in `evidence/b2-backup-restore.png`.

I used a **logical** dump (`pg_dump`) rather than tarring the volume. A logical
dump is portable across Postgres versions and architectures and is consistent
without stopping the server. A tar of `/var/lib/postgresql/data` is a physical
copy: it only restores into the same major version, and it is a torn, possibly
unstartable copy unless Postgres is stopped first or you use `pg_basebackup`.
Both are in the script, with that caveat in a comment.

### Task 28 — The debugging drill

Compose overrides that cause each fault are in
[`docker/drills/`](docker/drills/); [`run-drills.sh`](docker/drills/run-drills.sh)
causes and diagnoses all four in one capture.

#### a. Exit code 137

- **Caused by:** `deploy.resources.limits.memory: 50M` plus an allocation loop.
- **Symptom:** container disappears; `docker ps -a` shows `Exited (137)`. No
  error in the app's own logs — it never got the chance to log anything.
- **Command that revealed it:**
  `docker inspect --format='{{.State.OOMKilled}}' <c>` → `true`, confirmed by
  `dmesg | tail -20` showing the kernel's OOM killer picking the process.
- **Fix:** raise the limit to something the workload needs, or reduce what the
  process holds. For Node specifically, also set `--max-old-space-size` *below*
  the container limit — V8 sizes its heap from the host's memory, not the
  cgroup's, so by default it will happily grow past the container limit and get
  killed while believing it has plenty of headroom.

**What 137 means.** 128 + 9: the 128 says "terminated by a signal", the 9 is
SIGKILL. Contrast 143 = 128 + 15 = SIGTERM, which means something asked politely
— a `docker stop`, or a Swarm rolling update — and is usually *normal*. Telling
those apart is most of the diagnosis. Note that 137 alone does **not** prove OOM:
`docker kill` also produces 137. `State.OOMKilled: true` is what distinguishes
them.

#### b. Service name will not resolve, IP works

- **Caused by:** putting `app` on its own `isolated` network that postgres is
  not attached to.
- **Symptom:** `getaddrinfo ENOTFOUND postgres`, while
  `ping 172.18.0.3` succeeds.
- **Command that revealed it:**
  `docker inspect <c> --format '{{json .NetworkSettings.Networks}}' | jq` —
  the two containers have no network in common.
- **Fix:** put both on the same user-defined network.

**Why.** Docker runs an embedded DNS resolver at `127.0.0.11` inside every
container, and it only answers for containers that share a **user-defined**
network. Different networks → the name does not exist. The IP still works
because the host can route between bridges — which is exactly what makes this
confusing, since "the network is fine, DNS is broken" looks like a DNS server
problem rather than a topology problem.

The bigger version of the same trap: the legacy default `bridge` network has no
service discovery at all. Anything started with a plain `docker run` and no
`--network` lands there and can never resolve a compose service name, no matter
how the compose stack is configured.

#### c. Volume mounted, directory empty

- **Caused by:** `- ./empty-folder:/app/node_modules`.
- **Symptom:** `Error: Cannot find module 'express'` — from an image that
  demonstrably contains express.
- **Command that revealed it:** `docker compose exec app ls -la /app/node_modules`
  (empty) plus `docker inspect --format='{{json .Mounts}}' <c> | jq` showing a
  bind mount at that path.
- **Fix:** do not mount over a path the image populates. For live-reload
  development the usual pattern is to mount the source but leave
  `node_modules` alone with an anonymous volume: `- ./src:/app/src` plus
  `- /app/node_modules`.

**Why.** A **bind mount replaces** whatever the image had at that path. It does
not merge and it does not overlay — the host directory is mounted over the top
and the image's contents there become unreachable for the life of the container.
They are still in the image; they are shadowed.

**Named volumes behave differently, and this is the part worth knowing.** When a
named volume is *empty and newly created*, Docker copies the image's contents at
that path into the volume before mounting it, so `- node_modules:/app/node_modules`
appears to work. But that copy happens **exactly once**. After the first run the
volume has its own contents and is used as-is, so rebuilding the image with an
added dependency changes nothing — the classic "I installed the package, rebuilt,
and it still says module not found", fixed only by deleting the volume. Bind
mounts never do the copy, even when the host directory is empty.

#### d. Port published, connection refused

- **Caused by:** `HOST=127.0.0.1`, so the app binds the container's loopback.
- **Symptom:** `docker compose ps` shows the container up with 3000 published;
  `curl localhost:3000` is refused; `docker compose exec app wget -qO-
  http://127.0.0.1:3000/healthz` works perfectly.
- **Command that revealed it:** `docker compose exec app netstat -lntp` →
  `tcp 127.0.0.1:3000 LISTEN`. `0.0.0.0:3000` would have pointed at the
  firewall or the publish flag instead.
- **Fix:** bind `0.0.0.0` (the app's default; the drill overrides it).

**Why.** `ports:` sets up forwarding from the host into the container's network
namespace, and traffic arrives on the container's `eth0`. A listener on
`127.0.0.1` inside that namespace is unreachable from outside it by design —
that is what loopback means. Same failure as Scenario A task 8, one layer down,
and the same diagnostic: refused means something answered with a RST, timed out
means the packets vanished.

---

## B3 — Instrumentation, Prometheus and Grafana

### Task 29 — Metrics

[`app/src/metrics.js`](app/src/metrics.js) and the middleware in
[`app/src/server.js`](app/src/server.js). All six required metrics, plus
`collectDefaultMetrics` for process/GC/heap.

Two implementation points I want to draw attention to:

**The `route` label is the Express pattern, never the path.** Taken from
`req.route.path` after routing, so `/api/notes/48213` is recorded as
`/api/notes/:id`. Using the real path would create one time series *per note id*
— 50,000 series from one endpoint, each with its own histogram buckets, which is
tens of thousands of series more than the rest of the app combined. That is
"high cardinality", and it kills a Prometheus far faster than traffic does,
because series count drives memory in the head block. Unmatched requests are
bucketed as `"unmatched"` rather than labelled with whatever URL was probed —
otherwise a vulnerability scanner walking random URLs would create unbounded
series on your 404 handler. There is a **test** asserting this
(`tests/api.test.js`, "the route label is a pattern, never a concrete id"), so
someone "simplifying" it to `req.path` gets a red CI run rather than a dead
Prometheus. `tenant` is safe to use as a label because it is bounded at 5 and it
is the dimension we actually want to slice by; a user id would not be.

**`db_queries_per_request` uses `AsyncLocalStorage`.** The naive approach — a
module-level counter reset per request — is wrong on an async server: dozens of
requests interleave on one event loop and the counts get attributed to whichever
request happens to finish next. `AsyncLocalStorage` propagates a per-request
store through every `await`, so the count belongs to the right request.

```
$ curl -s localhost:3000/metrics | head -50
```

### Task 30 — Prometheus

[`docker/prometheus.yml`](docker/prometheus.yml). `scrape_interval: 5s` rather
than the 15s default, because this exam's load runs for minutes and 15s gives
too few points for a legible p95. In production 15s is the right answer — scrape
interval is a storage cost multiplied by every series you have.

The target is `app:3000`, the compose service name, resolved by Docker's
embedded DNS. `localhost:3000` would be Prometheus's own container.

Evidence: `evidence/b3-targets-up.png` (`/targets` showing UP), and
`evidence/b3-query.png`.

### Task 31 — Load

[`app/loadtest.sh`](app/loadtest.sh) — 5 minutes, all endpoints, 5 tenants, with:

- a **30-second burst** at the halfway mark (20 extra concurrent workers), for
  the saturation panel;
- **acme as the deliberately bad tenant**, sending `?limit=5000` while everyone
  else sends `?limit=20`.

Summary output: `evidence/b3-loadtest-summary.png`.

### Task 32 — The dashboard

Dashboard `exam-REPLACE_WITH_EXAM_TOKEN`, exported to
[`grafana/dashboard.json`](grafana/dashboard.json). One provisioning detail that
matters: the datasource uid is pinned to `PROM_EXAM` in
`grafana/provisioning/datasources/prometheus.yml` and referenced by that uid in
the dashboard JSON. Without pinning, Grafana generates a random uid and the
exported dashboard shows "Datasource not found" on every panel when imported
anywhere else — the usual reason a shared dashboard looks empty.

#### Panel A — Top 5 slowest endpoints by p95

```promql
topk(5, histogram_quantile(0.95,
  sum by (le, route) (rate(http_request_duration_seconds_bucket[$__rate_interval]))))
```

`le` must survive the `sum by (...)` or the quantile is meaningless — that label
*is* the bucket boundary. Winner on my system: `<<FILL: route>>` at
`<<FILL>>s`.

#### Panel B — Most total time consumed

```promql
topk(5, sum by (route) (rate(http_request_duration_seconds_sum[$__rate_interval])))
```

The `_sum` series accumulates total seconds spent, so `rate(_sum)` is *seconds
of work per second*: a value of 3 means this route occupies 3 seconds of
processing for every wall-clock second, i.e. it needs 3 workers just to keep up.

Winner: `<<FILL: route>>` at `<<FILL>>s/s.

**Why A and B are different, and why B matters more.** A ranks by cost *per
request*. B ranks by cost × frequency — where the server's time actually goes.
An endpoint at 5 seconds called twice an hour contributes ~0.003 s/s of load;
one at 200 ms called 500 times a second contributes 100 s/s and needs a hundred
concurrent workers. The first wins panel A and is nearly irrelevant; the second
wins panel B and is the reason the box is on fire.

On my system `<<FILL>>` tops A and `<<FILL>>` tops B. `/healthz` is the clearest
illustration of the gap: individually trivial, but scraped and probed so often
that it can still climb panel B.

Practically: **A tells you what to apologise to a user for, B tells you what to
optimise.** Fixing the panel-A winner improves one person's experience; fixing
the panel-B winner gives capacity back to everyone. The one caveat is that B is
biased toward high-traffic endpoints that may already be efficient — so use B to
choose *where* to look and A to judge whether what you find is actually
pathological.

#### Panel C — Mean and p99 DB duration by query

```promql
# mean
sum by (query_name) (rate(db_query_duration_seconds_sum[$__rate_interval]))
/ sum by (query_name) (rate(db_query_duration_seconds_count[$__rate_interval]))
# p99
histogram_quantile(0.99,
  sum by (le, query_name) (rate(db_query_duration_seconds_bucket[$__rate_interval])))
```

Both on one panel so the *gap* is visible. Mean near p99 means consistent work;
a 2 ms mean with a 400 ms p99 means most calls are fine and a small share are
pathological — a cold cache, a lock, or one tenant with far more rows.

Observed: `tags_for_note` mean `<<FILL>>`, p99 `<<FILL>>`; `search_notes` mean
`<<FILL>>`, p99 `<<FILL>>`; `stats_join` mean `<<FILL>>`, p99 `<<FILL>>`.

#### Panel D — Slowest query and how often it runs

Table joining p99 duration and calls/sec by `query_name`.

Slowest: `<<FILL: probably search_notes or stats_join>>`.
Most frequent: `<<FILL: probably tags_for_note, because of the N+1>>`.

**Are they the same query? `<<FILL: no>>`** — and that is the interesting part.
The slowest query runs `<<FILL>>` times a second; `tags_for_note` is individually
fast but runs ~20× per `/api/notes` request, so its *total* cost is
`<<FILL>>`× higher. Same lesson as panels A vs B, one layer down.

#### Panel E — The N+1 detector

```promql
sum by (route) (rate(db_queries_per_request_sum[$__rate_interval]))
/ sum by (route) (rate(db_queries_per_request_count[$__rate_interval]))
```

`/api/notes` sits at ~21 with `limit=20`; every other route sits at 1–2. That
number *is* the N+1: one query for the notes plus one per note for its tags.
Screenshot: `evidence/b3-panel-e-n1.png`.

This is why the metric exists. A latency graph alone would show `/api/notes` as
"a bit slow" and you would go looking at query plans. Queries-per-request says
immediately that the problem is the *number* of round trips, not the cost of any
one of them — a distinction latency cannot make, because 21 fast queries and 1
slow one can produce the same total.

#### Panel F — Harmful queries over time

```promql
sum by (query_name) (rate(db_query_duration_seconds_count[$__rate_interval]))
- sum by (query_name) (rate(db_query_duration_seconds_bucket{le="0.05"}[$__rate_interval]))
```

Total rate minus the rate of everything at or under the boundary = rate of
queries slower than 50 ms.

**Threshold justification (50 ms).** From my own panel C, normal query duration
on this system is: `tags_for_note` p99 `<<FILL: e.g. 1.2ms>>`, `notes_list` p99
`<<FILL: e.g. 8ms>>`, `note_by_id` p99 `<<FILL: e.g. 0.9ms>>`. So the ordinary
working range is roughly `<<FILL>>`–`<<FILL>>` ms, and 50 ms is about
`<<FILL: e.g. 6x>>` the p99 of a normal query — clearly abnormal *for this
system*, not merely a round number. I would move it if the baseline moved; a
threshold that is not derived from a baseline is a guess.

The constraint that decided the exact figure: **the threshold must be an
existing histogram bucket edge.** `le="0.06"` returns no data at all, silently,
because no such bucket exists. My buckets include 0.05, and 0.05 was also the
closest edge to the "several times the normal p99" figure — which is a good
example of instrumentation design constraining analysis later.

#### Panel G — Rows returned distribution

```promql
histogram_quantile(0.99,
  sum by (le, query_name) (rate(db_rows_returned_bucket[$__rate_interval])))
```

p99 on `notes_list` is `<<FILL: ~5000>>` — that is Problem 4 visible: a client
asking for `?limit=5000` and being given it.

**What maximum I would set, and what the API should do above it.** Cap at
**100** for a general list endpoint. Reasoning from the data rather than taste:
p50 here is `<<FILL: 20>>`, so 100 is already several times the normal request
and covers legitimate use; 5000 rows is `<<FILL>>` KB of JSON that has to be
serialised, buffered and sent while holding a pool connection, and it is
essentially never what a UI needs.

On a request above the cap, the API should **clamp and say so**, not fail:
return 100 rows with the response reporting `limit: 100`, `requested: 5000`, a
`next` cursor, and a `Warning` header. Rejecting with 400 is defensible and
stricter, but it breaks existing clients on the day you deploy the fix, whereas
clamping degrades them gracefully. What it must not do is silently return fewer
rows with no indication — a client that pages by counting results would then
loop forever.

The deeper fix is to stop using `LIMIT/OFFSET` for deep pagination at all —
`OFFSET 40000` makes Postgres walk and discard 40,000 rows. Keyset pagination
(`WHERE id > $last ORDER BY id LIMIT $n`) is O(limit) regardless of depth.

#### Panel H — Error rate and p95 by tenant

```promql
histogram_quantile(0.95, sum by (le, tenant) (rate(http_request_duration_seconds_bucket[$__rate_interval])))
sum by (tenant) (rate(http_requests_total{status=~"5.."}[$__rate_interval]))
/ sum by (tenant) (rate(http_requests_total[$__rate_interval]))
```

Worst tenant: **acme**, p95 `<<FILL>>` against `<<FILL>>` for the others.

**Is it more data, or heavier requests?** Both are deliberately true of acme —
it holds 30,000 of the 50,000 notes *and* the load generator sends it
`?limit=5000` — so the panel alone cannot attribute it. Separating them needs a
controlled comparison, which the metrics already support:

1. Compare **like for like**: p95 for `route="/api/notes"` at the *same* limit
   across tenants. Send acme `?limit=20` for a minute and compare against
   globex at `?limit=20`. If acme is still slower, data volume matters. Result:
   `<<FILL>>`.
2. Compare **the same tenant at different weights**: globex at `?limit=5000` vs
   globex at `?limit=20`. If globex degrades to acme's numbers, request shape
   is the cause. Result: `<<FILL>>`.
3. Cross-check with `db_rows_returned` by tenant and `db_queries_per_request` —
   if acme's rows-returned is 250× and its latency is only `<<FILL>>`× worse,
   the cost is dominated by the request shape, not by the table size.

Expected answer, to be confirmed by the run: **primarily heavier requests.**
`idx_notes_tenant_id` exists, so having 30,000 rows costs an index lookup, not a
scan — but returning 5,000 of them costs 250× the row-fetching, serialisation
and N+1 tag queries. The 30,000 rows amplify it (deeper `OFFSET`s, more tags)
but the request shape dominates. My evidence for that claim is step 2:
`<<FILL>>`.

This is exactly the multi-tenant failure mode worth understanding — one tenant's
usage pattern degrading a shared service for everyone else. It is the argument
for per-tenant rate limits and per-tenant query cost budgets, not just global
ones.

#### Panel I — Saturation

`http_requests_in_flight` against overall p95, latency on a second axis.

**Did latency rise with concurrency, or later?** `<<FILL: observed>>`.

How to read it:

- **Simultaneous rise** → the bottleneck is per-request work. Each request is
  independently expensive (CPU, or a slow query), and more requests simply means
  proportionally more work. Fix the work.
- **Latency lags concurrency, then rises sharply** → requests are **queueing**
  behind a fixed-size resource. Here that is almost certainly the
  10-connection Postgres pool (`PG_POOL_MAX=10`): up to 10 concurrent requests
  proceed at full speed, and the 11th waits for a connection. That gives a flat
  latency line followed by a knee, which is the signature of a queue rather than
  of expensive work.
- Latency continuing to climb after the burst ends → the queue is still
  draining, which tells you the system was over capacity, not merely busy.

During my burst, in-flight went from `<<FILL>>` to `<<FILL>>` and p95 went from
`<<FILL>>` to `<<FILL>>`, with a `<<FILL>>` second lag — so the bottleneck is
`<<FILL>>`.

### Task 33 — The alert that fires

Rule: p95 latency on any route above **`<<FILL: e.g. 1.5s>>`** for
**`<<FILL: e.g. 2m>>`**. Screenshot in `Firing`: `evidence/b3-alert-firing.png`.
The equivalent Prometheus rules are in
[`docker/alert.rules.yml`](docker/alert.rules.yml).

**Why that threshold.** Normal p95 from panel A is `<<FILL>>`s on the heaviest
route and `<<FILL>>`s on the rest. I set the threshold at roughly
`<<FILL: 3-5x>>` the normal p95, which is high enough that ordinary variation
never reaches it and low enough that a user would already be unhappy. A
threshold set just above normal produces an alert that fires every day and gets
muted — an alert nobody trusts is worse than no alert, because it also trains
people to ignore the ones that matter.

**Why that `for` duration.** `for: 2m` means the condition must hold
continuously for two minutes before the alert fires. It exists to filter
transients: a single slow scrape, a garbage collection pause, a deploy, a
30-second burst that the system absorbs correctly. None of those need a human.

**What happens with `for: 0s`:** the alert fires on the first evaluation that
crosses the line and resolves on the next one that does not. Around a threshold,
normal jitter crosses it repeatedly, so you get *flapping* — a stream of
firing/resolved pairs, a pager going off at 3am for something that fixed itself
in 15 seconds, and eventually a muted alert.

The cost is detection latency: `for: 2m` means you learn about a real outage two
minutes late. So the duration should be tuned against how long you are willing
to be down, not set to a habitual value — a payments endpoint might justify
`30s` and the noise that comes with it; a background report endpoint might
justify `10m`. `for` is the knob that trades false positives against detection
speed, and picking it is a product decision, not a technical one.

### Task 34 — Fix one problem and prove it

Problem fixed: **`<<FILL: 3 — the missing index on tags.note_id>>`**

```sql
-- before
EXPLAIN ANALYZE SELECT name FROM tags WHERE note_id = 12345;
-- <<FILL: Seq Scan on tags ... rows=150000 ... actual time=X>>

CREATE INDEX idx_tags_note_id ON tags (note_id);
ANALYZE tags;

-- after
EXPLAIN ANALYZE SELECT name FROM tags WHERE note_id = 12345;
-- <<FILL: Index Scan using idx_tags_note_id ... actual time=Y>>
```

Improvement: `<<FILL: X>>ms → `<<FILL: Y>>`ms, `<<FILL>>`×.

Postgres does **not** create an index on the referencing side of a foreign key.
It requires a unique index on the *referenced* side (the primary key, which
exists), because that is what the constraint needs to validate. The referencing
column gets nothing, which is why `tags.note_id` was unindexed despite being a
declared foreign key. This also makes deletes on `notes` slow, since every
delete must scan `tags` to check the constraint.

Grafana panel spanning both periods with a deploy annotation:
`evidence/b3-fix-before-after.png`.

**What the fix cost.**

```sql
SELECT pg_size_pretty(pg_relation_size('idx_tags_note_id'));   -- <<FILL: e.g. 3.3 MB>>
SELECT pg_size_pretty(pg_relation_size('tags'));               -- <<FILL>>
```

| | Before | After |
| --- | --- | --- |
| Disk | — | `<<FILL>>` for the index |
| `INSERT` of 10,000 tags | `<<FILL>>ms` | `<<FILL>>ms` |
| `SELECT ... WHERE note_id=$1` | `<<FILL>>ms` | `<<FILL>>ms` |

Every write now maintains a b-tree as well as the heap, and the index competes
for shared buffers. For this workload — read-heavy, writes rare — that is
obviously worth it. For a write-heavy append-only log it might not be, and that
is the actual reason not to index everything by reflex.

**Which problem I would fix next, and what I would measure first.**

Next: **the N+1 (Problem 1)**, because panel B says `/api/notes` dominates total
time and panel E says it is doing 21 queries per request. Note that the index I
just added makes each of those 21 queries fast, which *masks* the N+1 in a
latency graph — panel E still shows it plainly. That is a good argument for
keeping a queries-per-request metric permanently.

Before doing it I would measure:

1. `db_queries_per_request` for `/api/notes` at the limits real clients use, to
   confirm it scales with `limit` rather than being a fixed overhead.
2. The share of `/api/notes` latency spent in `tags_for_note` — panel B by
   `query_name`. If tags are only 10% of the request, the N+1 is not the
   bottleneck and I would be optimising the wrong thing.
3. Round-trip latency to the database. The N+1 is a *round trip* problem: at
   0.1 ms it is nearly free, at 2 ms across an availability zone it dominates.
   This is why the same code is fine in dev and awful in production.
4. The p99 of `limit`, because the N+1's cost is linear in it — `?limit=5000`
   means 5,001 queries, which is Problems 1 and 4 multiplying each other.

Fixing the N+1 and the unbounded limit together is more valuable than either
alone, which the metrics show and reading the code does not.

---

## B4 — Swarm

Stack file: [`docker/stack.yml`](docker/stack.yml).

### Task 35 — Deploy

**Nodes used: `<<FILL: one / two>>`.** `docker node ls` and
`docker stack services notes` in `evidence/b4-stack.png`.

The stack pulls `ghcr.io/rasel-xs/notes-api:v1` from the registry.
`build:` is ignored entirely by `docker stack deploy` — it does not warn, the
service simply never starts on a node that lacks the image.

### Task 36 — Scale to 5

`docker service scale notes_app=5`, then 50 requests counted by `X-Served-By`:

```
<<FILL: paste the uniq -c output showing 5 distinct hostnames>>
```

`-H "Connection: close"` is essential. Without it curl reuses a single keep-alive
connection, the routing mesh keeps that TCP connection pinned to the same task,
and you see one hostname and conclude scaling is broken. The distribution is
also not perfectly even — the mesh uses IPVS round-robin per *connection*, not
per request.

### Task 37 — Rolling update

```
<<FILL: awk '{print $2}' update-log.txt | sort | uniq -c>>
```

Non-200s: `<<FILL: be honest — report the real number>>`.

If any: the causes, in the order I would check them —

1. **No graceful shutdown.** Swarm sends SIGTERM and SIGKILLs after
   `stop_grace_period`. Without a handler, in-flight requests die. My app has
   one (`server.close()` then drain), and the exec-form CMD ensures node is PID
   1 and actually receives the signal.
2. **`stop-first` ordering.** The default removes a task before its replacement
   is ready, so capacity dips. `order: start-first` fixes it, at the cost of
   needing spare capacity during the rollout.
3. **No healthcheck**, so a task counts as ready the instant the process
   starts — before it can serve. `start-first` without a healthcheck buys
   almost nothing.
4. **The routing mesh's own convergence.** Even when everything above is right,
   IPVS rules take a moment to update, so a small number of connections can be
   sent to a task that is shutting down. This is why zero is genuinely hard and
   why a single-digit failure count is a more credible answer than zero.

### Task 38 — Break v3 and roll back

`docker/Dockerfile.v3broken` sets `BREAK_HEALTHZ=1`, so `/healthz` returns 500,
the container healthcheck never passes, the task never reaches `healthy`, and
`failure_action: rollback` puts v2 back.

- `docker service ps` during the failure: `evidence/b4-v3-failed.png`
- back on v2 afterwards: `evidence/b4-rolled-back.png`
- `UpdateStatus` showing `rollback_completed`: `evidence/b4-rollback-status.png`
- **Time from deploy to full rollback: `<<FILL: e.g. 1m48s>>`**, from the
  timestamps in `docker service ps`. It is roughly
  `monitor (20s) + healthcheck retries (3 × 5s + start_period 10s) + rollback
  delay`, per failing task.

**What if the image had no healthcheck?** Swarm would **not** have noticed.
Without one, a task is `running` — and therefore "successful" — as soon as its
process starts, and a broken `/healthz` is just an endpoint returning 500 that
nothing is asking about. The update would complete normally, report success, and
roll 500s out to all five replicas. `failure_action: rollback` would never
trigger, because from Swarm's point of view nothing failed.

That is the general lesson and it is the same one as Scenario A task 15: an
orchestrator can only detect what you have told it to measure. A restart policy
answers "is the process alive?"; only a healthcheck answers "is it working?".
It would only have been caught if the app *crashed* on startup — which is why I
deliberately broke v3 by failing the healthcheck rather than by exiting, since
an exit would have been caught by the restart policy and would have proved
nothing about health.

### Task 39 — Limits vs reservations

`docker service update --reserve-memory 8G notes_app` on a `<<FILL: 2>>`GB node:

```
<<FILL: docker service ps notes_app --no-trunc
        -> "no suitable node (insufficient resources on 1 node)", state Pending>>
```

**The difference.**

- A **limit** is a runtime ceiling, enforced by the kernel through cgroups. The
  container physically cannot exceed it: past the memory limit the OOM killer
  ends it (exit 137, task 28a); past the CPU limit it is throttled. A limit
  protects *other* workloads from this container.
- A **reservation** is a *scheduling* promise, and nothing else. Swarm will only
  place the task on a node with that much unclaimed capacity, and subtracts it
  from that node's available pool for future placement decisions. It does not
  reserve any memory at runtime, does not guarantee the memory is actually
  available later, and does not constrain the container's behaviour in any way.
  A reservation protects *this* container from being scheduled somewhere it
  cannot fit.

What I observed makes the distinction concrete: with an 8G reservation the task
is not killed, not started, not failed — it sits **Pending** with "no suitable
node", because the scheduler has nowhere to put it. Compare task 28a, where a
50M *limit* let the task start and then had the kernel kill it. Pending versus
OOMKilled is the clearest way to tell which one you configured.

The trap: reservations are what actually cause "my service will not start and
there is no error". Nothing crashed; the scheduler simply has no candidate node
and will wait forever. And over-reserving quietly wastes a cluster — every node
looks full while sitting idle.

### Task 40 — Scale down under traffic

5 → 2 with the loop running:

```
<<FILL: uniq -c output>>
```

Failures: `<<FILL>>`. Same mechanics as the rolling update: the tasks being
removed get SIGTERM and `stop_grace_period` to drain, so a graceful shutdown
handler is what keeps this near zero, while mesh convergence accounts for the
remainder.

---

## B5 — CI/CD

### Task 41 — The PR pipeline

[`.github/workflows/pr.yml`](../.github/workflows/pr.yml). Checkout → 10 tests
against a real Postgres service container → build → **run the image and curl
`/healthz`** → assert non-root and no `.env` in the image.

- Failing run: `<<FILL: URL>>` — `evidence/b5-pr-failed.png`
- Passing run after the fix: `<<FILL: URL>>` — `evidence/b5-pr-passed.png`

The tests use a real database on purpose. The bugs that matter in this app are
SQL and tenant scoping, and a mocked database cannot see either — the
cross-tenant read test is the one that would actually stop a data leak reaching
production.

The smoke step earns its place because an image can build perfectly and still be
unable to start: a typo in `CMD`, a runtime file excluded by `.dockerignore`, a
native module built against the wrong libc. Only running it finds that. It polls
for up to 30s rather than `sleep 10 && curl`, because a fixed sleep is either
flaky or slow and usually both.

### Task 42 — Caching

| Run | Duration |
| --- | --- |
| Cold (no cache) | `<<FILL: e.g. 2m41s>>` |
| Warm | `<<FILL: e.g. 51s>>` |
| Improvement | `<<FILL: e.g. 68%>>` |

Two independent caches: `actions/setup-node` with `cache: 'npm'` keyed on the
lockfile hash (so `npm ci` installs from the local cache instead of the
network), and `type=gha` for Docker layers via Buildx.

Worth knowing: GitHub's cache is scoped per branch, with read-only access to the
default branch's cache. A PR's first run therefore warms from `main`'s cache but
cannot write to it, so the very first run on a new dependency set is always cold.

### Task 43 — The main pipeline

[`.github/workflows/deploy.yml`](../.github/workflows/deploy.yml). Builds, tags
with **both** `v1.0.<commit-count>` and the full git SHA (plus `latest`), pushes
to GHCR.

**No long-lived credentials.** GHCR auth uses `${{ github.token }}`, which
GitHub mints per run and expires when the job ends. There is no
`AWS_SECRET_ACCESS_KEY` and no static access key anywhere in this repository —
the OIDC pattern is included commented at the bottom of the file and is what
Scenario C uses.

The SSH deploy key **is** a long-lived secret and I am not pretending otherwise.
What limits it: it is scoped to the `production` environment so only an approved
deployment can read it, it should be a dedicated key restricted with
`command="..."` in the server's `authorized_keys` so it can only run the deploy
script, and it is rotatable from one place.

Multi-arch (`linux/amd64,linux/arm64`) is enabled. It matters here because the
VPS is amd64 and my laptop is an arm64 Mac: a single-arch amd64 image runs on
the Mac only under emulation, and an arm64-only image will not run on the VPS at
all — it fails with `exec format error`, which reads like a corrupt binary
rather than an architecture mismatch. The cost is roughly double the build time,
since the non-native architecture is built under QEMU.

Package page with multiple tags: `evidence/b5-ghcr-tags.png`.

### Task 44 — The approval gate

`environment: production` with a required reviewer configured in
Settings → Environments.

- Paused with "Review pending deployments": `evidence/b5-approval-pending.png`
- After approval: `evidence/b5-approval-approved.png`
- New tag live on the VPS: `evidence/b5-vps-new-version.png`

The gate does more than pause: environment-scoped secrets are unreadable by any
job that has not passed it, so the SSH key cannot be exfiltrated by a workflow
change alone.

### Task 45 — Break it three ways

| # | How | Run |
| --- | --- | --- |
| 1 | Inverted an assertion in `tests/api.test.js` | `<<FILL: URL>>` |
| 2 | `COPY nonexistent-file /app/` in the Dockerfile | `<<FILL: URL>>` |
| 3 | Deploy step pointed at a wrong service name | `<<FILL: URL>>` |

**Production survived the failed deploy** — `evidence/b5-prod-survived.png`
showing `docker service ps notes_app` still on the previous image tag and a
successful `curl`.

**What made the failed deploy safe.**

1. **`docker service update` is a rolling in-place update, not a
   delete-and-recreate.** The existing tasks keep serving until new ones are
   healthy. At no point does a working version stop running.
2. **`--update-failure-action rollback` plus a healthcheck** — a task that never
   becomes healthy causes an automatic revert to the previous image.
3. **`start-first` ordering** — capacity never dips below the current replica
   count during the attempt.
4. **The pipeline is ordered so cheap checks fail first.** The test and build
   failures never reached the deploy job at all: `needs:` means a red build
   cannot deploy, so two of the three failures could not have touched production
   even in principle.
5. **Immutable, uniquely-tagged images** — every build is `v1.0.N` and a SHA, so
   "the previous version" is a specific artefact that still exists in the
   registry, not whatever `latest` happened to point at.

**What would have happened with `docker service rm` + recreate:** the service is
deleted first, so the site is down from that moment. If the recreate then fails
— bad image, wrong tag, registry unreachable, a typo in the create command —
there is *nothing running at all* and no automatic path back. You would be
recovering by hand, under pressure, from a shell. The rollback is also lost:
Swarm's `--rollback` restores a service's *previous spec*, and a deleted service
has no history. Worst of all, the failure window is the whole deploy rather than
the moment of failure, so the outage starts before you know anything is wrong.

That is the general principle: deploys should be **additive then cut over**, not
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
