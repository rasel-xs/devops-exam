#!/usr/bin/env python3
"""Summarise a Prometheus /metrics exposition page read from stdin.

Written because I got the label ORDER wrong three times in task 29 with
grep/sed one-liners. prom-client emits `_sum`/`_count` as
{app,route} but `_bucket` as {le,app,route}, and http_requests_total puts
`status` after `route`. Anything that pattern-matches a fixed order is a bug
waiting to print an empty result that looks like a missing metric.

This parses `name{k="v",...} value` properly and looks labels up by NAME.
"""
import re
import sys
from collections import defaultdict

LINE = re.compile(r'^([a-zA-Z_:][a-zA-Z0-9_:]*)(?:\{(.*)\})?\s+(-?[\d.eE+]+|NaN)$')
LABEL = re.compile(r'(\w+)="((?:[^"\\]|\\.)*)"')

samples = []
for raw in sys.stdin:
    raw = raw.strip()
    if not raw or raw.startswith('#'):
        continue
    m = LINE.match(raw)
    if not m:
        continue
    name, labelstr, value = m.groups()
    labels = dict(LABEL.findall(labelstr or ''))
    try:
        samples.append((name, labels, float(value)))
    except ValueError:
        samples.append((name, labels, float('nan')))


def pairs(metric, key):
    """Return {key_value: (sum, count)} for a histogram."""
    acc = defaultdict(lambda: [0.0, 0.0])
    for name, labels, value in samples:
        if name == metric + '_sum':
            acc[labels.get(key, '?')][0] = value
        elif name == metric + '_count':
            acc[labels.get(key, '?')][1] = value
    return acc


print('=== status codes (a wall of 404s means the id ranges were wrong) ===')
by_status = defaultdict(float)
for name, labels, value in samples:
    if name == 'http_requests_total':
        by_status[labels.get('status', '?')] += value
for k in sorted(by_status):
    print('  {:<5} {:>10.0f}'.format(k, by_status[k]))

print()
print('=== mean DB queries per request, per route ===')
for route, (s, c) in sorted(pairs('db_queries_per_request', 'route').items(),
                            key=lambda kv: -(kv[1][0] / kv[1][1] if kv[1][1] else 0)):
    if c:
        print('  {:<20} {:>8.2f}  over {:.0f} requests'.format(route, s / c, c))

print()
print('=== rows returned per query name (the unbounded limit) ===')
for q, (s, c) in sorted(pairs('db_rows_returned', 'query_name').items(),
                        key=lambda kv: -(kv[1][0] / kv[1][1] if kv[1][1] else 0)):
    if c:
        print('  {:<20} mean {:>10.1f} rows over {:.0f} calls'.format(q, s / c, c))

print()
print('=== requests per route ===')
by_route = defaultdict(float)
for name, labels, value in samples:
    if name == 'http_requests_total':
        by_route[labels.get('route', '?')] += value
for k, v in sorted(by_route.items(), key=lambda kv: -kv[1]):
    print('  {:<20} {:>10.0f}'.format(k, v))
