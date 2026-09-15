// Scenario C3 (tasks 55-58) -- file attachments in S3, via presigned URLs.
//
// The app never streams file bytes. It decides WHO may touch WHICH key, and then
// hands the client a URL that S3 itself will honour for a short time. So the
// security of the whole feature is the decision made in this file, before
// anything is signed.
//
// Key layout (task 57):
//   tenants/<tenant>/private/<uuid>-<name>   presigned only, never public
//   public/<tenant>/<uuid>-<name>            readable by anyone with a plain URL
//                                            (bucket policy allows s3:GetObject
//                                            on public/* and nothing else)
const crypto = require('node:crypto');
const path = require('node:path');
const express = require('express');
const { S3Client, PutObjectCommand, GetObjectCommand } = require('@aws-sdk/client-s3');
const { getSignedUrl } = require('@aws-sdk/s3-request-presigner');

const BUCKET = process.env.S3_BUCKET || '';
const REGION = process.env.AWS_REGION || process.env.AWS_DEFAULT_REGION || 'eu-north-1';
const UPLOAD_TTL_SECONDS = 300;
const DOWNLOAD_TTL_SECONDS = 60;          // task 56: exactly 60 seconds

// Credentials come from the ECS task role (abdur-ecs-task-role) through the
// container credentials endpoint; nothing is configured here.
//
// requestChecksumCalculation: SDK v3 (since early 2025) adds a CRC32 checksum of
// the body to PutObject by default. For a PRESIGNED PUT there is no body at
// signing time, so the URL would carry the checksum of an empty body and a real
// upload with `curl --upload-file` would be rejected. WHEN_REQUIRED leaves it out.
const s3 = new S3Client({
  region: REGION,
  requestChecksumCalculation: 'WHEN_REQUIRED',
  responseChecksumValidation: 'WHEN_REQUIRED',
});

// A filename becomes part of a key, so it is reduced to a safe basename: no
// directories, no "..", nothing outside [A-Za-z0-9._-].
function safeName(name) {
  const base = path.posix.basename(String(name || '').replace(/\\/g, '/'));
  const cleaned = base.replace(/[^A-Za-z0-9._-]/g, '_').replace(/^\.+/, '').slice(0, 100);
  return cleaned || null;
}

// TASK 58 -- tenant isolation, decided in application code BEFORE signing.
//
// A key is only ever signed for the tenant it is filed under. acme asking for
// tenants/globex/... gets a 403 and no URL, even though the task role itself
// could read the object: the role is shared by every tenant, so IAM cannot tell
// tenants apart -- only this check can.
function keyBelongsToTenant(key, slug) {
  if (typeof key !== 'string' || key.length > 512) return false;
  if (key.includes('..') || key.includes('//') || key.startsWith('/')) return false;
  return key.startsWith(`tenants/${slug}/`) || key.startsWith(`public/${slug}/`);
}

function publicUrl(key) {
  return `https://${BUCKET}.s3.${REGION}.amazonaws.com/${key.split('/').map(encodeURIComponent).join('/')}`;
}

function router(resolveTenant) {
  const r = express.Router();

  // Without a bucket (e.g. the Scenario B deployment on the VPS) the feature is
  // off, clearly, instead of signing URLs for a bucket that does not exist.
  r.use('/api/attachments', (req, res, next) => {
    if (!BUCKET) return res.status(503).json({ error: 'attachments are not configured (S3_BUCKET unset)' });
    next();
  });

  // TASK 55 -- presigned PUT.
  r.post('/api/attachments/upload-url', resolveTenant, async (req, res, next) => {
    const name = safeName(req.body && req.body.filename);
    if (!name) return res.status(400).json({ error: 'filename is required' });
    const visibility = (req.body && req.body.visibility) === 'public' ? 'public' : 'private';
    const id = crypto.randomUUID();
    const key = visibility === 'public'
      ? `public/${req.tenantSlug}/${id}-${name}`
      : `tenants/${req.tenantSlug}/private/${id}-${name}`;
    try {
      const url = await getSignedUrl(s3, new PutObjectCommand({ Bucket: BUCKET, Key: key }),
        { expiresIn: UPLOAD_TTL_SECONDS });
      const body = { key, visibility, method: 'PUT', url, expiresInSeconds: UPLOAD_TTL_SECONDS };
      if (visibility === 'public') body.publicUrl = publicUrl(key);
      res.status(201).json(body);
    } catch (err) { next(err); }
  });

  // TASKS 56 and 58 -- presigned GET, 60 s, only for the caller's own tenant.
  // The key contains slashes, so the client URL-encodes it into one path
  // segment (tenants%2Facme%2F...); Express decodes req.params.key.
  r.get('/api/attachments/:key/download-url', resolveTenant, async (req, res, next) => {
    const key = req.params.key;
    if (!keyBelongsToTenant(key, req.tenantSlug)) {
      console.warn(JSON.stringify({
        level: 'warn', msg: 'attachment access denied: key outside caller tenant',
        tenant: req.tenantSlug, key,
      }));
      return res.status(403).json({ error: 'forbidden: this key does not belong to your tenant' });
    }
    try {
      const url = await getSignedUrl(s3, new GetObjectCommand({ Bucket: BUCKET, Key: key }),
        { expiresIn: DOWNLOAD_TTL_SECONDS });
      res.json({
        key, method: 'GET', url, expiresInSeconds: DOWNLOAD_TTL_SECONDS,
        expiresAt: new Date(Date.now() + DOWNLOAD_TTL_SECONDS * 1000).toISOString(),
      });
    } catch (err) { next(err); }
  });

  return r;
}

module.exports = { router, keyBelongsToTenant, safeName, DOWNLOAD_TTL_SECONDS, UPLOAD_TTL_SECONDS };
