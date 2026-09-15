// Scenario C4 (tasks 59-62) -- one app instance, many tenants, chosen by hostname.
//
// Two ways a request can name its tenant:
//
//   HEADER MODE (default: tests, Scenario B, the ECS/ALB deployment)
//     X-Tenant: acme
//
//   HOST MODE (TENANT_BASE_DOMAIN set: the VPS behind nginx, C4)
//     acme.abdur.169.58.246.108.nip.io   -> nginx's regex server block extracts
//                                           "acme" and SETS X-Tenant itself,
//                                           overwriting anything the client sent
//     notes.globex-corp.<ip>.sslip.io    -> nginx's default server sends NO
//                                           X-Tenant; the app looks the hostname
//                                           up in tenant_domains (verified only)
//     anything else                      -> "domain not configured" page (62.1)
//
// The app itself never parses the tenant out of Host for subdomains: that is
// nginx's job, so there is exactly one place where "which tenant is this" is
// decided for them, and it is not a header the client controls (62.3).
const dns = require('node:dns').promises;
const express = require('express');
const db = require('./db');

const BASE_DOMAIN = (process.env.TENANT_BASE_DOMAIN || '').toLowerCase();   // abdur.169.58.246.108.nip.io
const PUBLIC_PORT = process.env.PUBLIC_PORT || '';                          // 8141
const PUBLIC_IP = process.env.PUBLIC_IP || '';                              // 169.58.246.108
const HOST_MODE = BASE_DOMAIN !== '';

// ---------------------------------------------------------------------------
// Task 60 -- slug validation.
//
// A slug becomes a DNS label (acme.<base>) AND a key prefix (tenants/acme/) AND
// a metrics label, so it has to be safe as all three:
//   * 3-32 chars, lowercase letters, digits, hyphen; starts and ends alphanumeric
//     (a DNS label cannot start or end with "-")
//   * NO DOTS: "a.b" would be a sub-sub-domain -- acme.evil would be served as
//     tenant "acme.evil" by a naive wildcard, or shadow tenant "evil"
//   * no "--": labels like "xn--..." are punycode, i.e. a lookalike domain
//   * not a reserved name: these either mean something to people (www, admin,
//     login -- a phishing page on admin.<base> looks official) or collide with
//     infrastructure this service uses or may add later (api, mail, status)
// ---------------------------------------------------------------------------
const RESERVED = new Set([
  'www', 'api', 'admin', 'administrator', 'app', 'apps', 'mail', 'smtp', 'imap', 'pop',
  'ftp', 'ns', 'ns1', 'ns2', 'dns', 'mx', 'root', 'abdur', 'static', 'assets', 'cdn',
  'status', 'health', 'healthz', 'readyz', 'metrics', 'grafana', 'prometheus',
  'dashboard', 'login', 'logout', 'signin', 'signup', 'auth', 'oauth', 'sso', 'account',
  'billing', 'support', 'help', 'docs', 'blog', 'dev', 'test', 'staging', 'prod',
  'internal', 'localhost', 'default', 'null', 'undefined',
]);
const SLUG_RE = /^[a-z0-9][a-z0-9-]{1,30}[a-z0-9]$/;

function validateSlug(slug) {
  if (typeof slug !== 'string') return 'slug is required';
  if (slug.includes('.')) return 'slug must not contain dots (it would become a nested subdomain)';
  if (slug !== slug.toLowerCase()) return 'slug must be lowercase';
  if (!SLUG_RE.test(slug)) return 'slug must be 3-32 characters: a-z, 0-9 and "-", starting and ending with a letter or digit';
  if (slug.includes('--')) return 'slug must not contain "--" (reserved for punycode labels)';
  if (RESERVED.has(slug)) return `slug "${slug}" is reserved`;
  return null;
}

const HOSTNAME_RE = /^(?=.{4,253}$)([a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z]{2,63}$/;

function tenantUrl(slug) {
  if (!HOST_MODE) return null;
  return `http://${slug}.${BASE_DOMAIN}${PUBLIC_PORT ? `:${PUBLIC_PORT}` : ''}/`;
}

// ---------------------------------------------------------------------------
// Task 62.1 -- the page an unknown or unverified domain gets.
// ---------------------------------------------------------------------------
function notConfigured(res, host) {
  const safe = String(host).replace(/[^a-z0-9.:-]/gi, '');
  res.status(404).type('html').send(
    `<!doctype html><title>Domain not configured</title>
<h1>Domain not configured</h1>
<p><b>${safe}</b> is not connected to any workspace on this service.</p>
<p>If this is your domain, add it in your workspace settings and verify it.</p>\n`);
}

// Probes answer on any hostname (nginx and the orchestrators call them by IP).
// '/' is deliberately NOT here: a visitor to an unknown domain's home page must
// get the "domain not configured" page, not the app's banner.
const PROBES = new Set(['/healthz', '/readyz', '/metrics']);

// Runs before every route in host mode. Decides, from the hostname, whether the
// request may reach a tenant at all -- so an unknown domain can never fall
// through to a default tenant or to someone else's data.
async function gate(req, res, next) {
  if (!HOST_MODE) return next();
  if (req.get('X-Tenant')) return next();                  // set by nginx's subdomain block
  const host = (req.hostname || '').toLowerCase();
  if (PROBES.has(req.path)) return next();
  // Direct access by IP or on the box itself (Scenario B's :3140, curl on the
  // VPS) and the bare base domain (where POST /api/tenants lives) are not tenant
  // hosts; resolveTenant will ask for a tenant as usual.
  if (!host || host === BASE_DOMAIN || host === PUBLIC_IP || host === 'localhost' || /^[\d.]+$/.test(host)) {
    return next();
  }
  try {
    // Deliberately NOT cached: a domain that is removed or re-assigned must stop
    // resolving to the old tenant immediately. (A cache keyed by hostname is the
    // classic place for a cross-tenant leak.)
    const r = await db.query('custom_domain_lookup',
      `SELECT t.id, t.slug FROM tenant_domains d JOIN tenants t ON t.id = d.tenant_id
        WHERE d.domain = $1 AND d.verified`, [host]);
    if (r.rowCount === 0) return notConfigured(res, host);
    req.customDomainTenant = r.rows[0];
    next();
  } catch (err) { next(err); }
}

// Slug -> id, cached: tenants are never deleted here, so the mapping is stable.
const tenantCache = new Map();

async function resolveTenant(req, res, next) {
  if (req.customDomainTenant) {
    req.tenantId = req.customDomainTenant.id;
    req.tenantSlug = req.customDomainTenant.slug;
    return next();
  }
  const slug = req.get('X-Tenant');
  if (!slug) {
    return res.status(400).json({ error: 'X-Tenant header is required' });
  }
  try {
    if (!tenantCache.has(slug)) {
      const r = await db.query('tenant_lookup', 'SELECT id FROM tenants WHERE slug = $1', [slug]);
      if (r.rowCount === 0) return res.status(404).json({ error: `unknown tenant: ${slug}` });
      tenantCache.set(slug, r.rows[0].id);
    }
    req.tenantId = tenantCache.get(slug);
    req.tenantSlug = slug;
    next();
  } catch (err) { next(err); }
}

function router() {
  const r = express.Router();

  // -------------------------------------------------------------------------
  // Task 60 -- POST /api/tenants {"slug","name"}: row, seed data, S3 prefix, URL.
  // No DNS record and no nginx change: the wildcard record already covers every
  // label under the base domain, and the regex server block already accepts it.
  // -------------------------------------------------------------------------
  r.post('/api/tenants', async (req, res, next) => {
    const { slug, name } = req.body || {};
    const problem = validateSlug(slug);
    if (problem) return res.status(422).json({ error: problem });
    if (typeof name !== 'string' || !name.trim() || name.length > 100) {
      return res.status(422).json({ error: 'name is required (1-100 characters)' });
    }
    const client = await db.pool.connect();
    try {
      await client.query('BEGIN');
      const ins = await client.query(
        'INSERT INTO tenants (slug, name) VALUES ($1, $2) ON CONFLICT (slug) DO NOTHING RETURNING id, slug, name',
        [slug, name.trim()]);
      if (ins.rowCount === 0) {
        await client.query('ROLLBACK');
        return res.status(409).json({ error: `slug "${slug}" is already taken` });
      }
      const tenant = ins.rows[0];
      const seed = await client.query(
        `INSERT INTO notes (tenant_id, title, body) VALUES
           ($1, $2, 'This workspace was provisioned automatically.'),
           ($1, 'Getting started', 'Create notes with POST /api/notes.'),
           ($1, 'Your address', $3)
         RETURNING id`,
        [tenant.id, `Welcome to ${tenant.name}`, tenantUrl(slug) || 'header mode: send X-Tenant']);
      await client.query('COMMIT');
      // S3 has no directories: tenants/<slug>/ exists as soon as the first
      // object is written under it, and the bucket policy and task role already
      // cover tenants/* -- so there is nothing to create, only a prefix to report.
      res.status(201).json({
        tenant, url: tenantUrl(slug), seededNotes: seed.rowCount,
        s3Prefix: `tenants/${slug}/`,
      });
    } catch (err) {
      await client.query('ROLLBACK').catch(() => {});
      next(err);
    } finally { client.release(); }
  });

  // -------------------------------------------------------------------------
  // Tasks 61 and 62.2 -- custom domains, claimed by the tenant whose host the
  // request arrived on, unique across ALL tenants, usable only once verified.
  // -------------------------------------------------------------------------
  r.post('/api/domains', resolveTenant, async (req, res, next) => {
    const domain = String((req.body && req.body.domain) || '').toLowerCase().replace(/\.$/, '');
    if (!HOSTNAME_RE.test(domain)) return res.status(422).json({ error: 'domain must be a valid hostname' });
    if (BASE_DOMAIN && (domain === BASE_DOMAIN || domain.endsWith(`.${BASE_DOMAIN}`))) {
      return res.status(422).json({ error: `subdomains of ${BASE_DOMAIN} are assigned automatically` });
    }
    try {
      const r2 = await db.query('domain_claim',
        'INSERT INTO tenant_domains (domain, tenant_id) VALUES ($1, $2) RETURNING domain, verified',
        [domain, req.tenantId]);
      res.status(201).json({
        ...r2.rows[0], tenant: req.tenantSlug,
        next: `point an A record for ${domain} at ${PUBLIC_IP || 'this server'}, then POST /api/domains/${domain}/verify`,
      });
    } catch (err) {
      if (err.code === '23505') {                     // unique_violation on the primary key
        return res.status(409).json({
          error: `domain ${domain} is already claimed by another workspace`,
          constraint: err.constraint,
        });
      }
      next(err);
    }
  });

  r.post('/api/domains/:domain/verify', resolveTenant, async (req, res, next) => {
    const domain = String(req.params.domain).toLowerCase();
    try {
      const own = await db.query('domain_owned',
        'SELECT domain FROM tenant_domains WHERE domain = $1 AND tenant_id = $2', [domain, req.tenantId]);
      if (own.rowCount === 0) return res.status(404).json({ error: 'no such domain in this workspace' });
      let addresses = [];
      try { addresses = await dns.resolve4(domain); } catch (e) { addresses = []; }
      if (!PUBLIC_IP || !addresses.includes(PUBLIC_IP)) {
        return res.status(422).json({ domain, verified: false, addresses, expected: PUBLIC_IP || null });
      }
      await db.query('domain_verify', 'UPDATE tenant_domains SET verified = true WHERE domain = $1 AND tenant_id = $2',
        [domain, req.tenantId]);
      res.json({ domain, verified: true, addresses });
    } catch (err) { next(err); }
  });

  r.get('/api/domains', resolveTenant, async (req, res, next) => {
    try {
      const d = await db.query('domain_list',
        'SELECT domain, verified, created_at FROM tenant_domains WHERE tenant_id = $1 ORDER BY domain', [req.tenantId]);
      res.json({ tenant: req.tenantSlug, domains: d.rows });
    } catch (err) { next(err); }
  });

  return r;
}

module.exports = { gate, resolveTenant, router, validateSlug, RESERVED, HOST_MODE };
