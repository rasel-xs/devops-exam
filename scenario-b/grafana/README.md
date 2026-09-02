# Grafana

`dashboard.json` is provisioned automatically by compose — it is mounted at
`/var/lib/grafana/dashboards` and picked up by
`provisioning/dashboards/dashboards.yml`.

```
http://localhost:3001   admin / admin
```

**Before your first screenshot**, replace the token in the title so it appears
in every panel capture:

```bash
sed -i '' "s/root-vmi3536696-1788282556-1536d427/$EXAM_TOKEN/" dashboard.json   # macOS
docker compose -f ../docker/docker-compose.yml restart grafana
```

`allowUiUpdates: true` is set, so panels can be edited in the browser. Re-export
afterwards with **Dashboard settings → JSON Model** and paste back into
`dashboard.json`, otherwise the next `docker compose up` reverts your edits.

## Task 33 — the alert

The alert rule is created in the Grafana UI (Alerting → Alert rules) so it can
be screenshotted in `Firing` state. The same conditions also exist as Prometheus
rules in `../docker/alert.rules.yml`, which is what I would actually run in
production — a Grafana-only alert stops working when Grafana is down, which is
precisely when you want to hear from it.

Export the Grafana rule after creating it:

```bash
curl -s -u admin:admin http://localhost:3001/api/v1/provisioning/alert-rules \
  | python3 -m json.tool > alert-rule.json
```
