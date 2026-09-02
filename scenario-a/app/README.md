# Scenario A app

Zero-dependency Node HTTP server. Deployed to the VPS at `/srv/abdur/app/src/server.js`.

```bash
PORT=3100 node server.js
curl localhost:3100/            # Hello from backend on port 3100 (host ...)
curl localhost:3100/healthz     # ok
curl localhost:3100/whoami      # JSON: what the app thinks your IP is
curl localhost:3100/crash       # replies, then exits 1
curl localhost:3100/hang        # replies, then never answers again
time curl localhost:3100/slow   # 45 seconds
```

Two copies run for the load-balancing task, via the systemd template unit:

```bash
sudo systemctl enable --now abdur-myapp@3101 abdur-myapp@3102
```
