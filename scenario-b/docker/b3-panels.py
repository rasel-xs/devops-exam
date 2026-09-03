#!/usr/bin/env python3
"""Evaluate every panel query in grafana/dashboard.json against Prometheus.

A screenshot proves a dashboard exists. This proves every panel actually
RESOLVES to data -- which is the failure a screenshot taken at the wrong moment
hides, and the failure that a mistyped metric name produces silently (Grafana
draws an empty panel, not an error).

usage: b3-panels.py [prometheus_url] [rate_interval]
"""
import json
import sys
import urllib.parse
import urllib.request

PROM = sys.argv[1] if len(sys.argv) > 1 else 'http://127.0.0.1:9190'
RATE = sys.argv[2] if len(sys.argv) > 2 else '1m'

dash = json.load(open('grafana/dashboard.json'))
print('dashboard: {}   uid={}   panels={}'.format(
    dash.get('title'), dash.get('uid'), len(dash.get('panels', []))))
print('substituting $__rate_interval -> {} (Grafana computes it from the'
      ' panel width and the 5s scrape interval)'.format(RATE))

failures = []

for panel in dash['panels']:
    print()
    print('=' * 78)
    print('{}  [{}]'.format(panel['title'], panel['type']))
    # Every target must point at the pinned datasource uid, or the panel is
    # blank on any Grafana but the one it was exported from.
    for target in panel.get('targets', []):
        ds = target.get('datasource') or panel.get('datasource') or {}
        uid = ds.get('uid') if isinstance(ds, dict) else ds
        expr = target.get('expr', '').replace('$__rate_interval', RATE)
        legend = target.get('legendFormat', '')
        print('  -- {}   (datasource uid={})'.format(legend or '(no legend)', uid))
        url = PROM + '/api/v1/query?' + urllib.parse.urlencode({'query': expr})
        try:
            with urllib.request.urlopen(url, timeout=20) as r:
                data = json.load(r)
        except Exception as exc:                     # noqa: BLE001
            print('     REQUEST FAILED: {}'.format(exc))
            failures.append((panel['title'], legend, str(exc)))
            continue
        if data.get('status') != 'success':
            print('     PROMQL ERROR: {}'.format(data.get('error')))
            failures.append((panel['title'], legend, data.get('error')))
            continue
        rows = data['data']['result']
        if not rows:
            print('     NO DATA  <-- panel would be blank')
            failures.append((panel['title'], legend, 'no data'))
            continue
        for s in rows[:8]:
            m = dict(s['metric'])
            m.pop('__name__', None)
            lbl = ','.join('{}={}'.format(k, v) for k, v in sorted(m.items()))
            print('     {:>12}  {}'.format(s['value'][1], lbl or '(no labels)'))
        if len(rows) > 8:
            print('     ... {} more series'.format(len(rows) - 8))

print()
print('=' * 78)
if failures:
    print('{} target(s) produced nothing:'.format(len(failures)))
    for title, legend, why in failures:
        print('  {:<52} {}'.format(title[:52], why))
    print()
    print('NOTE: "no data" is only a bug if that series should exist right now.')
    print('A p95 for a route nobody called in the last {} is legitimately empty.'.format(RATE))
else:
    print('every panel target returned data')
