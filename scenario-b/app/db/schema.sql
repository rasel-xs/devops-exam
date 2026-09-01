-- Notes API schema.
--
-- Two indexes are DELIBERATELY ABSENT (see scenario-b/ANSWERS.md):
--   * tags.note_id            -- Postgres does not index the referencing side
--                                of a foreign key automatically, only the
--                                referenced primary key. Its absence is what
--                                makes /api/stats and the N+1 slow.
--   * anything usable by      -- a leading-wildcard LIKE cannot use a b-tree
--     `body LIKE '%x%'`          anyway; it needs pg_trgm or a tsvector GIN.

CREATE TABLE IF NOT EXISTS tenants (
  id   SERIAL PRIMARY KEY,
  slug TEXT UNIQUE NOT NULL
);

CREATE TABLE IF NOT EXISTS notes (
  id         SERIAL PRIMARY KEY,
  tenant_id  INT NOT NULL REFERENCES tenants(id),
  title      TEXT NOT NULL,
  body       TEXT NOT NULL,
  created_at TIMESTAMP DEFAULT now()
);

CREATE TABLE IF NOT EXISTS tags (
  id      SERIAL PRIMARY KEY,
  note_id INT NOT NULL REFERENCES notes(id),
  name    TEXT NOT NULL
);

-- This one IS created: every single API query filters by tenant_id, and
-- without it even a "correct" endpoint scans all 50,000 rows. Leaving it out
-- would make every measurement in B3 about this index instead of about the
-- four problems the exam is actually asking me to find.
CREATE INDEX IF NOT EXISTS idx_notes_tenant_id ON notes (tenant_id);

-- The task 34 fix, applied later and measured before/after. Left commented so
-- the "before" state is reproducible from a clean database:
-- CREATE INDEX idx_tags_note_id ON tags (note_id);
