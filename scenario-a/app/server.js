#!/usr/bin/env node
// Scenario A demo app. Zero dependencies on purpose: it must start from a
// systemd unit on a fresh VPS with nothing but `node` installed.
//
// Endpoints required by the brief:
//   GET /         -> text including its own port and hostname
//   GET /healthz  -> 200 while the process is alive AND not hung
//   GET /slow     -> replies after 45s (A5 task 19, the 504)
//   GET /crash    -> replies, then exits non-zero (A4 task 13, the restart limit)
//   GET /hang     -> replies, then stops answering forever but stays alive (task 15)
//   GET /whoami   -> echoes the socket peer + headers (A5 task 16, proxy headers)

const http = require('http');
const os = require('os');

const PORT = parseInt(process.env.PORT || '3100', 10);
const HOST = process.env.HOST || '0.0.0.0';
const HOSTNAME = os.hostname();

// Once true, every route except /crash stops responding. The socket is still
// accepted and the process is still alive -- which is exactly why
// Restart=on-failure cannot see this failure. See ANSWERS.md task 15.
let hung = false;

function send(res, code, body, type = 'text/plain') {
  res.writeHead(code, { 'Content-Type': type, 'X-Served-By': HOSTNAME });
  res.end(body);
}

const server = http.createServer((req, res) => {
  const url = new URL(req.url, `http://${req.headers.host || 'localhost'}`);
  const path = url.pathname;

  // /crash stays reachable while hung so the crash-loop test still works.
  if (path === '/crash') {
    send(res, 200, 'bye\n');
    setTimeout(() => process.exit(1), 100);
    return;
  }

  if (hung) {
    // Never write, never end, never destroy: the client waits until it times out.
    return;
  }

  switch (path) {
    case '/':
      send(res, 200, `Hello from backend on port ${PORT} (host ${HOSTNAME})\n`);
      return;

    case '/healthz':
      send(res, 200, 'ok\n');
      return;

    case '/slow':
      setTimeout(() => send(res, 200, `finally, from port ${PORT}\n`), 45000);
      return;

    case '/hang':
      send(res, 200, 'now hanging\n');
      hung = true;
      return;

    case '/whoami':
      // remoteAddress is what the app *sees*. Behind nginx without proxy headers
      // this is always 127.0.0.1 -- that is the point of task 16.
      send(res, 200, JSON.stringify({
        port: PORT,
        hostname: HOSTNAME,
        remoteAddress: req.socket.remoteAddress,
        realIpHeader: req.headers['x-real-ip'] || null,
        forwardedFor: req.headers['x-forwarded-for'] || null,
        headers: req.headers,
      }, null, 2) + '\n', 'application/json');
      return;

    default:
      send(res, 404, 'not found\n');
  }
});

server.listen(PORT, HOST, () => {
  console.log(`abdur-myapp listening on ${HOST}:${PORT} as ${HOSTNAME} (pid ${process.pid})`);
});

// Without this, systemctl stop waits for TimeoutStopSec then SIGKILLs us.
for (const sig of ['SIGTERM', 'SIGINT']) {
  process.on(sig, () => {
    console.log(`${sig} received, shutting down`);
    server.close(() => process.exit(0));
    setTimeout(() => process.exit(0), 5000).unref();
  });
}
