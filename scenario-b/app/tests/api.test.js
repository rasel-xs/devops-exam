// Unit/integration tests for the PR pipeline (B5 task 41).
//
// These need a real Postgres -- CI provides one as a service container. They
// are deliberately NOT mocked: a test that mocks the database cannot catch the
// thing that actually breaks in this app, which is SQL and tenant scoping.
//
//   DATABASE_URL=postgres://notes:notes@localhost:5432/notes npm test
const { test, before, after, describe } = require('node:test');
const assert = require('node:assert/strict');

process.env.APP_VERSION = process.env.APP_VERSION || 'test';
const { app } = require('../src/server');
const db = require('../src/db');

let server;
let base;

before(async () => {
  await db.pool.query(`
    CREATE TABLE IF NOT EXISTS tenants (id SERIAL PRIMARY KEY, slug TEXT UNIQUE NOT NULL);
    CREATE TABLE IF NOT EXISTS notes (
      id SERIAL PRIMARY KEY, tenant_id INT NOT NULL REFERENCES tenants(id),
      title TEXT NOT NULL, body TEXT NOT NULL, created_at TIMESTAMP DEFAULT now());
    CREATE TABLE IF NOT EXISTS tags (
      id SERIAL PRIMARY KEY, note_id INT NOT NULL REFERENCES notes(id), name TEXT NOT NULL);
  `);
  await db.pool.query(
    `INSERT INTO tenants (slug) VALUES ('acme'), ('globex') ON CONFLICT DO NOTHING`);

  // Port 0 = let the kernel pick a free one. Hard-coding 3000 in a test is how
  // you get a suite that passes locally and fails in CI because something else
  // already has the port.
  server = app.listen(0);
  await new Promise((r) => server.once('listening', r));
  base = `http://127.0.0.1:${server.address().port}`;
});

after(async () => {
  await new Promise((r) => server.close(r));
  await db.pool.end();
});

describe('probes', () => {
  test('GET /healthz returns 200 without touching the database', async () => {
    const res = await fetch(`${base}/healthz`);
    assert.equal(res.status, 200);
    assert.equal((await res.json()).status, 'ok');
  });

  test('GET /readyz returns 200 when the database answers', async () => {
    const res = await fetch(`${base}/readyz`);
    assert.equal(res.status, 200);
    assert.equal((await res.json()).status, 'ready');
  });

  test('GET /metrics exposes the six required metric families', async () => {
    await fetch(`${base}/healthz`);                 // generate at least one sample
    const body = await (await fetch(`${base}/metrics`)).text();
    for (const name of [
      'http_requests_total',
      'http_request_duration_seconds',
      'db_query_duration_seconds',
      'db_queries_per_request',
      'db_rows_returned',
      'http_requests_in_flight',
    ]) {
      assert.ok(body.includes(name), `missing metric: ${name}`);
    }
  });

  test('the route label is a pattern, never a concrete id', async () => {
    // The high-cardinality regression test. If someone "helpfully" changes the
    // label to req.path, this fails instead of quietly killing Prometheus.
    const created = await fetch(`${base}/api/notes`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json', 'X-Tenant': 'acme' },
      body: JSON.stringify({ title: 'label test', body: 'x' }),
    });
    const note = await created.json();
    await fetch(`${base}/api/notes/${note.id}`, { headers: { 'X-Tenant': 'acme' } });

    const body = await (await fetch(`${base}/metrics`)).text();
    assert.ok(body.includes('route="/api/notes/:id"'), 'route pattern label missing');
    assert.ok(!body.includes(`route="/api/notes/${note.id}"`),
      'route label contains a concrete note id -- high cardinality');
  });
});

describe('tenancy', () => {
  test('a request without X-Tenant is rejected with 400', async () => {
    const res = await fetch(`${base}/api/notes`);
    assert.equal(res.status, 400);
  });

  test('an unknown tenant is rejected with 404', async () => {
    const res = await fetch(`${base}/api/notes`, { headers: { 'X-Tenant': 'nope-inc' } });
    assert.equal(res.status, 404);
  });

  test('a note created by one tenant is invisible to another', async () => {
    const created = await fetch(`${base}/api/notes`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json', 'X-Tenant': 'acme' },
      body: JSON.stringify({ title: 'acme secret', body: 'do not leak', tags: ['private'] }),
    });
    assert.equal(created.status, 201);
    const note = await created.json();

    const mine = await fetch(`${base}/api/notes/${note.id}`, { headers: { 'X-Tenant': 'acme' } });
    assert.equal(mine.status, 200);
    assert.equal((await mine.json()).title, 'acme secret');

    // Same id, different tenant. This is THE test for a multi-tenant app: a
    // 200 here is a cross-tenant data leak, not a failing assertion.
    const theirs = await fetch(`${base}/api/notes/${note.id}`, { headers: { 'X-Tenant': 'globex' } });
    assert.equal(theirs.status, 404, 'cross-tenant read returned data');
  });
});

describe('notes', () => {
  test('POST /api/notes rejects a missing body with 400', async () => {
    const res = await fetch(`${base}/api/notes`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json', 'X-Tenant': 'acme' },
      body: JSON.stringify({ title: 'no body' }),
    });
    assert.equal(res.status, 400);
  });

  test('GET /api/notes paginates and returns tags', async () => {
    for (const i of [1, 2, 3]) {
      await fetch(`${base}/api/notes`, {
        method: 'POST',
        headers: { 'Content-Type': 'application/json', 'X-Tenant': 'acme' },
        body: JSON.stringify({ title: `page test ${i}`, body: 'searchable content', tags: ['t'] }),
      });
    }
    const res = await fetch(`${base}/api/notes?limit=2&page=1`, { headers: { 'X-Tenant': 'acme' } });
    assert.equal(res.status, 200);
    const data = await res.json();
    assert.equal(data.notes.length, 2);
    assert.ok(Array.isArray(data.notes[0].tags));
  });

  test('GET /api/notes/:id returns 404 for an id that does not exist', async () => {
    const res = await fetch(`${base}/api/notes/99999999`, { headers: { 'X-Tenant': 'acme' } });
    // B5 task 45, failure 1: deliberately inverted. A missing note is a 404,
    // not a 200. Reverted in the commit after the failing run is recorded.
    assert.equal(res.status, 200);
  });
});
