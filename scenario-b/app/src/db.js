// Postgres access. Every query goes through query() so it is timed, counted and
// attributed to a logical name -- `query_name` is a hand-written label like
// 'notes_list', never the SQL text, because SQL text is unbounded cardinality.
const { Pool } = require('pg');
const { AsyncLocalStorage } = require('node:async_hooks');
const m = require('./metrics');

// AsyncLocalStorage carries a per-request context through every await without
// threading a parameter through every function. It is how the queries-per-
// request counter can be accurate on an async handler: the store follows the
// promise chain, so the count belongs to the right request even with dozens of
// requests interleaved on one event loop.
const requestContext = new AsyncLocalStorage();

const pool = new Pool({
  connectionString: process.env.DATABASE_URL ||
    'postgres://notes:notes@localhost:5432/notes',
  // Deliberately small, like a real deployment. This is the resource that the
  // N+1 and the 45-second endpoint actually exhaust -- see Scenario A task 19.
  max: parseInt(process.env.PG_POOL_MAX || '10', 10),
  idleTimeoutMillis: 30000,
  connectionTimeoutMillis: 5000,
});

pool.on('error', (err) => {
  // An idle client erroring out must not take the process down.
  console.error(JSON.stringify({ level: 'error', msg: 'idle pg client error', err: err.message }));
});

async function query(name, text, params = []) {
  const stop = m.dbQueryDuration.startTimer({ query_name: name });
  try {
    const res = await pool.query(text, params);
    m.dbRowsReturned.observe({ query_name: name }, res.rowCount ?? 0);
    return res;
  } finally {
    stop();
    const ctx = requestContext.getStore();
    if (ctx) ctx.queries += 1;   // counted even when the query throws
  }
}

async function ping() {
  await query('readyz_ping', 'SELECT 1');
}

module.exports = { pool, query, ping, requestContext };
