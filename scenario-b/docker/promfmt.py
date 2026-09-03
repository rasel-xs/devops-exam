#!/usr/bin/env python3
"""Pretty-print Prometheus HTTP API JSON from stdin.

Exists as a FILE and not as `python3 -c '...'` inside the shell script for one
reason: the shell wrapper is single-quoted, so any double quote inside the
Python has to be backslash-escaped, and an escaped quote is not legal inside an
f-string expression. Every one of my inline formatters died with
`SyntaxError: unexpected character after line continuation character`. A file
has no quoting layer at all.

usage:  ... | promfmt.py query
        ... | promfmt.py targets
"""
import json
import sys


def fmt_query(d):
    if d.get('status') != 'success':
        print('  QUERY ERROR:', d.get('error'))
        return
    rows = d['data']['result']
    if not rows:
        print('  (no data)')
        return
    for s in rows:
        m = dict(s['metric'])
        m.pop('__name__', None)
        labels = ','.join('{}={}'.format(k, v) for k, v in sorted(m.items()))
        print('  {:>12.4f}  {}'.format(float(s['value'][1]), labels or '(no labels)'))


def fmt_targets(d):
    for t in d['data']['activeTargets']:
        job = t['labels'].get('job', '?')
        print('  job={:<12} health={:<6} url={}'.format(job, t['health'], t['scrapeUrl']))
        print('     interval={}  lastDuration={:.4f}s  lastScrape={}'.format(
            t.get('scrapeInterval'), t.get('lastScrapeDuration', 0), t.get('lastScrape')))
        if t.get('lastError'):
            print('     ERROR: {}'.format(t['lastError']))


mode = sys.argv[1] if len(sys.argv) > 1 else 'query'
data = json.load(sys.stdin)
(fmt_targets if mode == 'targets' else fmt_query)(data)
