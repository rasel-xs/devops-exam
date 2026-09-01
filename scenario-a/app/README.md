# Scenario A app

Zero-dependency Node HTTP server. Deployed to the VPS at `/srv/app/src/server.js`.

```bash
PORT=3000 node server.js
curl localhost:3000/            # Hello from backend on port 3000 (host ...)
curl localhost:3000/healthz     # ok
curl localhost:3000/whoami      # JSON: what the app thinks your IP is
curl localhost:3000/crash       # replies, then exits 1
curl localhost:3000/hang        # replies, then never answers again
time curl localhost:3000/slow   # 45 seconds
```

Two copies run for the load-balancing task, via the systemd template unit:

```bash
sudo systemctl enable --now myapp@3001 myapp@3002
```
