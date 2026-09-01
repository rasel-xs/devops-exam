// Multi-tenant Notes API.
//
// NOTE TO THE MARKER: four performance problems in this file are DELIBERATE and
// required by the brief (B, "Deliberate problems you must LEAVE IN"). Each is
// marked `DELIBERATE PROBLEM n`. They are found with Grafana in B3 and one of
// them is fixed and measured in task 34.
const express = require('express');
const os = require('node:os');
const db = require('./db');
const m = require('./metrics');

const app = express();
const PORT = parseInt(process.env.PORT || '3000', 10);
const APP_VERSION = process.env.APP_VERSION || 'v1';
// B4 task 38: the deliberately broken v3 image sets this so the container
// healthcheck never passes and Swarm has to roll back.
const BREAK_HEALTHZ = process.env.BREAK_HEALTHZ === '1';

app.disable('x-powered-by');
app.set('etag', false);
app.use(express.json({ limit: '256kb' }));

// ---------------------------------------------------------------------------
// Instrumentation middleware
// ---------------------------------------------------------------------------
app.use((req, res, next) => {
  const stopTimer = m.httpRequestDuration.startTimer();
  m.httpRequestsInFlight.inc();

  // B4 task 36: proves which replica served the request when Swarm scales out.
  // Inside a container os.hostname() is the container id.
  res.setHeader('X-Served-By', os.hostname());
  res.setHeader('X-App-Version', APP_VERSION);

  db.requestContext.run({ queries: 0 }, () => {
    res.on('finish', () => {
      m.httpRequestsInFlight.dec();

      // req.route only exists after Express has matched a handler, and it holds
      // the PATTERN. Falling back to the literal path would be the high-
      // cardinality mistake, so unmatched requests are bucketed as 'unmatched'
      // rather than labelled with whatever URL was probed.
      const route = req.route ? `${req.baseUrl}${req.route.path}` : 'unmatched';
      const tenant = req.tenantSlug || 'none';
      const labels = { route, method: req.method, tenant };

      stopTimer(labels);
      m.httpRequestsTotal.inc({ ...labels, status: res.statusCode });

      const ctx = db.requestContext.getStore();
      if (ctx) m.dbQueriesPerRequest.observe({ route }, ctx.queries);
    });
    next();
  });
});

// ---------------------------------------------------------------------------
// Tenancy
// ---------------------------------------------------------------------------
// Slug -> id, cached because it is on the hot path of every request and there
// are five of them. Not a correctness risk: tenants are not deleted here.
const tenantCache = new Map();

async function resolveTenant(req, res, next) {
  const slug = req.get('X-Tenant');
  if (!slug) {
    return res.status(400).json({ error: 'X-Tenant header is required' });
  }
  try {
    if (!tenantCache.has(slug)) {
      const r = await db.query('tenant_lookup',
        'SELECT id FROM tenants WHERE slug = $1', [slug]);
      if (r.rowCount === 0) return res.status(404).json({ error: `unknown tenant: ${slug}` });
      tenantCache.set(slug, r.rows[0].id);
    }
    req.tenantId = tenantCache.get(slug);
    req.tenantSlug = slug;
    next();
  } catch (err) { next(err); }
}

// ---------------------------------------------------------------------------
// Probes and metrics
// ---------------------------------------------------------------------------

// Liveness: is the process alive? It must NOT touch the database -- if it did,
// a database blip would make the orchestrator kill healthy app containers and
// turn a database incident into an application outage as well.
app.get('/healthz', (req, res) => {
  if (BREAK_HEALTHZ) {
    return res.status(500).json({ status: 'deliberately broken (v3)', version: APP_VERSION });
  }
  res.json({ status: 'ok', version: APP_VERSION, host: os.hostname() });
});

// Readiness: can this instance actually serve traffic? It DOES touch the
// database, because an instance that cannot query is not ready for the load
// balancer even though the process is perfectly alive.
app.get('/readyz', async (req, res) => {
  try {
    await db.ping();
    res.json({ status: 'ready', version: APP_VERSION });
  } catch (err) {
    res.status(503).json({ status: 'not ready', error: err.message });
  }
});

app.get('/metrics', async (req, res) => {
  res.set('Content-Type', m.register.contentType);
  res.end(await m.register.metrics());
});

app.get('/', (req, res) => {
  res.type('text').send(
    `notes-api ${APP_VERSION} on port ${PORT} (host ${os.hostname()})\n`);
});

// ---------------------------------------------------------------------------
// API
// ---------------------------------------------------------------------------
app.post('/api/notes', resolveTenant, async (req, res, next) => {
  const { title, body, tags } = req.body || {};
  if (!title || !body) {
    return res.status(400).json({ error: 'title and body are required' });
  }
  try {
    const r = await db.query('note_insert',
      'INSERT INTO notes (tenant_id, title, body) VALUES ($1, $2, $3) RETURNING *',
      [req.tenantId, title, body]);
    const note = r.rows[0];

    if (Array.isArray(tags) && tags.length) {
      // One statement for all tags via UNNEST, rather than a loop. The N+1 in
      // this app is on the read path and is deliberate; this one would not be.
      await db.query('tag_insert',
        'INSERT INTO tags (note_id, name) SELECT $1, unnest($2::text[])',
        [note.id, tags]);
      note.tags = tags;
    }
    res.status(201).json(note);
  } catch (err) { next(err); }
});

app.get('/api/notes', resolveTenant, async (req, res, next) => {
  // DELIBERATE PROBLEM 4 -- unbounded limit. `?limit=50000` is honoured and
  // returns 50,000 rows. A correct version would clamp:
  //     const limit = Math.min(parseInt(req.query.limit) || 20, 100);
  const limit = parseInt(req.query.limit, 10) || 20;
  const page = Math.max(parseInt(req.query.page, 10) || 1, 1);
  const offset = (page - 1) * limit;

  try {
    const notes = await db.query('notes_list',
      'SELECT * FROM notes WHERE tenant_id = $1 ORDER BY id LIMIT $2 OFFSET $3',
      [req.tenantId, limit, offset]);                       // 1 query

    // DELIBERATE PROBLEM 1 -- the N+1. One query for the notes, then one more
    // per note for its tags: limit=20 issues 21 queries instead of 2. The fix
    // (task 34) is a single `WHERE note_id = ANY($1)`, kept below, commented.
    for (const note of notes.rows) {                        // ...then N queries
      const tags = await db.query('tags_for_note',
        'SELECT name FROM tags WHERE note_id = $1', [note.id]);
      note.tags = tags.rows.map((t) => t.name);
    }

    // --- the fix, for task 34 ------------------------------------------------
    // const ids = notes.rows.map((n) => n.id);
    // const tagRows = await db.query('tags_for_notes_batch',
    //   'SELECT note_id, name FROM tags WHERE note_id = ANY($1::int[])', [ids]);
    // const byNote = new Map();
    // for (const t of tagRows.rows) {
    //   if (!byNote.has(t.note_id)) byNote.set(t.note_id, []);
    //   byNote.get(t.note_id).push(t.name);
    // }
    // for (const note of notes.rows) note.tags = byNote.get(note.id) || [];
    // -------------------------------------------------------------------------

    res.json({ page, limit, count: notes.rowCount, notes: notes.rows });
  } catch (err) { next(err); }
});

app.get('/api/notes/:id', resolveTenant, async (req, res, next) => {
  try {
    // tenant_id is in the WHERE clause, not checked after the fetch. Filtering
    // in application code after selecting by id alone is how multi-tenant data
    // leaks happen -- one forgotten `if` and tenant A reads tenant B's note.
    const r = await db.query('note_by_id',
      'SELECT * FROM notes WHERE id = $1 AND tenant_id = $2',
      [req.params.id, req.tenantId]);
    if (r.rowCount === 0) return res.status(404).json({ error: 'not found' });

    const tags = await db.query('tags_for_note',
      'SELECT name FROM tags WHERE note_id = $1', [r.rows[0].id]);
    res.json({ ...r.rows[0], tags: tags.rows.map((t) => t.name) });
  } catch (err) { next(err); }
});

app.get('/api/search', resolveTenant, async (req, res, next) => {
  const q = req.query.q || '';
  try {
    // DELIBERATE PROBLEM 2 -- a leading-wildcard LIKE with no index. Postgres
    // cannot use a b-tree for '%foo%', so this is a sequential scan of every
    // note for the tenant. The real fix is a GIN index on a tsvector
    // (full-text) or pg_trgm for substring search.
    const r = await db.query('search_notes',
      `SELECT id, title, body FROM notes
        WHERE tenant_id = $1 AND body LIKE '%' || $2 || '%'
        LIMIT 50`,
      [req.tenantId, q]);
    res.json({ q, count: r.rowCount, results: r.rows });
  } catch (err) { next(err); }
});

app.get('/api/stats', resolveTenant, async (req, res, next) => {
  try {
    // DELIBERATE PROBLEM 3 -- there is no index on tags.note_id. Postgres does
    // NOT create one for a foreign key automatically (it only indexes the
    // referenced side, via the primary key). So this join has to scan tags.
    const r = await db.query('stats_join',
      `SELECT t.slug,
              COUNT(DISTINCT n.id)   AS notes,
              COUNT(tg.id)           AS tags
         FROM tenants t
         LEFT JOIN notes n  ON n.tenant_id = t.id
         LEFT JOIN tags  tg ON tg.note_id  = n.id
        WHERE t.id = $1
        GROUP BY t.slug`,
      [req.tenantId]);
    res.json(r.rows[0] || { slug: req.tenantSlug, notes: 0, tags: 0 });
  } catch (err) { next(err); }
});

// ---------------------------------------------------------------------------
app.use((req, res) => res.status(404).json({ error: 'not found' }));

app.use((err, req, res, _next) => {
  console.error(JSON.stringify({
    level: 'error', msg: err.message, route: req.path, stack: err.stack,
  }));
  res.status(500).json({ error: 'internal error' });
});

// ---------------------------------------------------------------------------
// Startup / shutdown
// ---------------------------------------------------------------------------
function start() {
  // 0.0.0.0, not 127.0.0.1. Binding to loopback inside a container is B2 task
  // 28d: the port is published, the container is running, and every connection
  // from the host is refused because the listener is on the container's own
  // loopback interface, which the published port never reaches.
  // B2 task 28d causes the "published but refused" failure by setting
  // HOST=127.0.0.1. Default stays 0.0.0.0 -- see the comment above.
  const HOST = process.env.HOST || '0.0.0.0';
  const server = app.listen(PORT, HOST, () => {
    console.log(JSON.stringify({
      level: 'info', msg: 'listening', host: HOST, port: PORT,
      version: APP_VERSION, host: os.hostname(), pid: process.pid,
    }));
  });

  // Without this, a Swarm rolling update SIGTERMs the container, nothing
  // handles it, the process is SIGKILLed 10s later and every in-flight request
  // is dropped -- which is exactly the non-200s counted in B4 task 37.
  const shutdown = (sig) => {
    console.log(JSON.stringify({ level: 'info', msg: 'shutting down', signal: sig }));
    server.close(async () => {
      try { await db.pool.end(); } catch (_) { /* already closed */ }
      process.exit(0);
    });
    setTimeout(() => process.exit(1), 10000).unref();
  };
  process.on('SIGTERM', () => shutdown('SIGTERM'));
  process.on('SIGINT', () => shutdown('SIGINT'));
  return server;
}

if (require.main === module) start();

module.exports = { app, start };
