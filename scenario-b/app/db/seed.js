// Seeds 5 tenants, 50,000 notes (deliberately uneven) and 150,000 tags.
//
// Every row is generated INSIDE Postgres with generate_series. Sending 200,000
// individual INSERTs from Node would mean 200,000 round trips and take minutes;
// this takes a couple of seconds because the data never crosses the wire.
const { pool, query } = require('../src/db');

const TENANTS = ['acme', 'globex', 'initech', 'umbrella', 'hooli'];

// acme gets 30,000 so that "one tenant is clearly worse" in Panel H has a real
// cause to disentangle: more data vs heavier requests. The load generator ALSO
// sends acme heavier requests, and task 32 panel H asks which one is
// responsible -- so both variables are deliberately present.
const DISTRIBUTION = { acme: 30000, globex: 8000, initech: 6000, umbrella: 4000, hooli: 2000 };

async function main() {
  const t0 = Date.now();
  console.log('seeding...');

  await query('seed_truncate', 'TRUNCATE tags, notes, tenants RESTART IDENTITY CASCADE');

  for (const slug of TENANTS) {
    await query('seed_tenant', 'INSERT INTO tenants (slug) VALUES ($1)', [slug]);
  }
  const { rows: tenants } = await query('seed_tenant_ids',
    'SELECT id, slug FROM tenants ORDER BY id');

  for (const t of tenants) {
    const n = DISTRIBUTION[t.slug];
    // Random-ish words in the body so /api/search has something to find.
    // md5(random()) gives 32 hex chars; concatenating four of them gives a body
    // long enough that a sequential scan actually costs something.
    await pool.query(
      `INSERT INTO notes (tenant_id, title, body, created_at)
       SELECT $1,
              'Note ' || g,
              md5(random()::text) || ' ' || md5(random()::text) || ' ' ||
              md5(random()::text) || ' ' || md5(random()::text),
              now() - (random() * interval '90 days')
         FROM generate_series(1, $2) g`,
      [t.id, n]);
    console.log(`  ${t.slug.padEnd(9)} ${n} notes`);
  }

  // 150,000 tags spread over the notes.
  //
  // My first version used `JOIN LATERAL (SELECT id FROM notes OFFSET
  // floor(random()*count) LIMIT 1)`, which reads on average 25,000 rows to
  // pick ONE note id -- 150,000 times over. That is billions of row visits and
  // it never finished. Because the ids are contiguous after
  // TRUNCATE ... RESTART IDENTITY, picking a number in [min,max] costs nothing.
  await pool.query(`
    WITH bounds AS (SELECT min(id) AS lo, max(id) AS hi FROM notes)
    INSERT INTO tags (note_id, name)
    SELECT b.lo + floor(random() * (b.hi - b.lo + 1))::int,
           (ARRAY['urgent','draft','review','archived','personal','work',
                  'idea','todo','done','blocked'])[floor(random()*10+1)]
      FROM generate_series(1, 150000) g, bounds b
  `);
  console.log('  150000 tags');

  const { rows } = await pool.query(`
    SELECT t.slug, count(DISTINCT n.id) notes, count(tg.id) tags
      FROM tenants t
      LEFT JOIN notes n ON n.tenant_id = t.id
      LEFT JOIN tags tg ON tg.note_id = n.id
     GROUP BY t.slug ORDER BY notes DESC`);
  console.table(rows);
  console.log(`done in ${((Date.now() - t0) / 1000).toFixed(1)}s`);
  await pool.end();
}

main().catch((e) => { console.error(e); process.exit(1); });
