# syntax=docker/dockerfile:1
# Multi-stage build. Build context is scenario-b/app:
#   docker build -f docker/Dockerfile -t notes-api:multi app/
# exam token: root-vmi3536696-1788282556-1536d427

# ---------------------------------------------------------------- deps -------
# Full node image here: npm needs python3/make/g++ to build any native module,
# and none of that is allowed anywhere near the final image.
FROM node:20-bookworm AS deps
WORKDIR /build

# package*.json is copied ALONE, before the source. This is the whole point of
# layer caching: `npm ci` only re-runs when the manifests change, so editing
# src/server.js reuses the cached dependency layer. Copying the source first
# would invalidate npm ci on every single code change (B1 task 23).
COPY package.json package-lock.json* ./

# `npm ci` not `npm install`: it installs exactly the lockfile, fails if the
# lockfile and package.json disagree, and is reproducible. --omit=dev keeps
# devDependencies out of the layer that gets copied forward.
RUN npm ci --omit=dev && npm cache clean --force

# ---------------------------------------------------------------- runtime ----
FROM node:20-alpine AS runtime
ENV NODE_ENV=production \
    PORT=3000 \
    APP_VERSION=v1

# wget is busybox's, already in alpine, and is used by HEALTHCHECK below. No
# curl, no bash, no compiler, no npm cache, no package manager metadata.
WORKDIR /app

# node:alpine already ships an unprivileged `node` user (uid 1000). Using it is
# safer than creating my own, because the image's own files are already owned
# correctly for it.
COPY --from=deps --chown=node:node /build/node_modules ./node_modules
COPY --chown=node:node package.json ./
COPY --chown=node:node src ./src
COPY --chown=node:node db ./db

# Everything below this line runs unprivileged. Note this is USER, not just
# "the app drops privileges itself" -- the container's PID 1 is non-root, so a
# container escape starts from uid 1000, not from root.
USER node

EXPOSE 3000

# The healthcheck asks the app a question rather than checking the process
# exists -- the same reasoning as the systemd watchdog in Scenario A.
# --start-period is what stops a slow first boot being counted as failure.
# It hits /healthz (liveness, no DB) rather than /readyz, so a database outage
# does not make the orchestrator kill every app container as well.
HEALTHCHECK --interval=10s --timeout=3s --start-period=15s --retries=3 \
  CMD wget --quiet --tries=1 --spider http://127.0.0.1:3000/healthz || exit 1

# Exec form, so node is PID 1 and receives SIGTERM directly. The shell form
# (`CMD node src/server.js`) would put /bin/sh at PID 1, and sh does not forward
# signals -- the app would never see SIGTERM and every rolling update would
# hard-kill it after the grace period. That is a real cause of the dropped
# requests counted in B4 task 37.
CMD ["node", "src/server.js"]
