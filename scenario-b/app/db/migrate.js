// Applies schema.sql. Idempotent (everything is IF NOT EXISTS), so it is safe
// to run on every container start.
const fs = require('node:fs');
const path = require('node:path');
const { pool } = require('../src/db');

(async () => {
  const sql = fs.readFileSync(path.join(__dirname, 'schema.sql'), 'utf8');
  // Retry, because `depends_on` in compose only waits for the container to
  // exist. B2 task 26 proves that the hard way; this is the app-side half of
  // the fix, and the reason a healthcheck condition in compose is the other.
  const deadline = Date.now() + 60_000;
  for (let attempt = 1; ; attempt++) {
    try {
      await pool.query(sql);
      console.log('migrations applied');
      break;
    } catch (err) {
      if (Date.now() > deadline) {
        console.error('migration failed after 60s:', err.message);
        process.exit(1);
      }
      console.log(`postgres not ready (attempt ${attempt}: ${err.message}), retrying in 2s`);
      await new Promise((r) => setTimeout(r, 2000));
    }
  }
  await pool.end();
})();
