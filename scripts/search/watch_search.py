#!/usr/bin/env python3
"""Watch search on one or more StreamX edges through a deploy. Read-only GETs.

Start it BEFORE merging a change that restarts `opensearch-sink`, leave it
running until every edge has switched, then stop it with Ctrl-C. It asks each
edge the same search about twice a second and prints a line only when
something changes:

  - the status: 200, a failure (an HTTP error, an empty 500 or a timeout), and
    back to 200;
  - the ranking: the top three results and their scores. A ranking change
    shows the moment the new template took over on that edge.

Then, per edge: how many searches it sent, how many failed, and the longest
run of consecutive failures in seconds, which is the number to put in the PR.
See docs/deploying.md, "What a deploy costs".

    python3 scripts/search/watch_search.py --edge https://<project>.<cluster>.prod-ext.streamx.cloud
    STREAMX_DELIVERY_URL=https://... python3 scripts/search/watch_search.py --minutes 60

--edge is repeatable: watch the old and the new edge side by side while moving
a mesh between regions, or every edge of a multi-edge mesh.

Standard library only. On Windows, type `py -3` for `python3`.
"""
from __future__ import annotations

import argparse
import datetime
import json
import sys
import threading
import time
import urllib.error
import urllib.parse
import os
import urllib.request


class SearchError(Exception):
    pass


def search_url(edge: str, template: str, params: dict[str, str]) -> str:
    return f'{edge}/search/{urllib.parse.quote(template)}/?' + urllib.parse.urlencode(params)


def now() -> float:
    """Swapped out by the tests."""
    return time.time()


def stamp(t: float) -> str:
    return datetime.datetime.fromtimestamp(t, datetime.timezone.utc).strftime('%H:%M:%S.%f')[:-4] + 'Z'


def fetch(url: str) -> dict:
    """One GET with a short timeout: during a restart a search can hang rather
    than fail, and a hang is an outage to the reader too."""
    request = urllib.request.Request(url, headers={'Accept': 'application/json'}, method='GET')
    try:
        with urllib.request.urlopen(request, timeout=5) as response:
            return json.load(response)
    except urllib.error.HTTPError as error:
        raise SearchError(f'HTTP {error.code}') from None
    except urllib.error.URLError as error:
        raise SearchError(f'unreachable: {error.reason}') from None


def fingerprint(body: dict, top: int = 3) -> str:
    """The top results with their scores to one decimal. The two replicas of an
    edge each have their own index, so their BM25 scores differ in the third
    decimal (measured 2026-10-13): full precision would print
    CHANGED on every other search."""
    hits = (body.get('hits') or {}).get('hits') or []

    def score(value):
        return f'{value:.1f}' if isinstance(value, (int, float)) else str(value)
    return ', '.join(f'{h.get("_id")} {score(h.get("_score"))}' for h in hits[:top]) or '(no hits)'


class Watch:
    """One edge's history: every probe is (time, ok, ranking fingerprint or error)."""

    def __init__(self, name: str, url: str):
        self.name, self.url = name, url
        self.sent = self.failed = 0
        self.ranking: str | None = None
        self.down_since: float | None = None
        self.longest_down = 0.0
        self.changes: list[tuple[float, str]] = []
        self.lines: list[str] = []

    def record(self, t: float, ok: bool, detail: str) -> str | None:
        """Update the history; return a line to print, or None if nothing changed."""
        self.sent += 1
        if not ok:
            self.failed += 1
            if self.down_since is None:
                self.down_since = t
                return f'{stamp(t)}  {self.name:<9} FAILING  {detail}'
            return None
        line = None
        if self.down_since is not None:
            down = t - self.down_since
            self.longest_down = max(self.longest_down, down)
            line = f'{stamp(t)}  {self.name:<9} back     after {down:.1f} s'
            self.down_since = None
        if detail != self.ranking:
            if self.ranking is not None:
                self.changes.append((t, detail))
            first = self.ranking is None
            self.ranking = detail
            text = f'{stamp(t)}  {self.name:<9} {"ranking " if first else "CHANGED "} {detail}'
            line = f'{line}\n{text}' if line else text
        return line

    def summary(self, t: float) -> str:
        if self.down_since is not None:
            self.longest_down = max(self.longest_down, t - self.down_since)
        changed = (f'ranking changed at {", ".join(stamp(x) for x, _ in self.changes)}'
                   if self.changes else 'ranking never changed')
        still = ' STILL FAILING' if self.down_since is not None else ''
        return (f'{self.name:<9} {self.sent} searches, {self.failed} failed, '
                f'longest outage {self.longest_down:.1f} s; {changed}{still}')


def probe(watch: Watch, fetch=fetch) -> tuple[bool, str]:
    try:
        return True, fingerprint(fetch(watch.url))
    except SearchError as error:
        return False, str(error)[:120]
    except Exception as error:  # a timeout or a reset is a failed search too
        return False, f'{type(error).__name__}: {str(error)[:100]}'


def run(watches, seconds, interval, out=sys.stdout, fetch=fetch, sleep=time.sleep):
    lock = threading.Lock()
    end = now() + seconds
    stop = threading.Event()

    def loop(watch):
        while not stop.is_set() and now() < end:
            ok, detail = probe(watch, fetch)
            line = watch.record(now(), ok, detail)
            if line:
                with lock:
                    print(line, file=out, flush=True)
            sleep(interval)

    threads = [threading.Thread(target=loop, args=(w,), daemon=True) for w in watches]
    for thread in threads:
        thread.start()
    try:
        for thread in threads:
            while thread.is_alive():
                thread.join(0.5)
    except KeyboardInterrupt:
        stop.set()
        for thread in threads:
            thread.join(5)
    t = now()
    print('', file=out)
    for watch in watches:
        print(watch.summary(t), file=out)
    return 0


def main(argv=None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.split('\n\n')[0])
    parser.add_argument('--edge', action='append',
                        help='delivery URL, https://<project>.<cluster>.prod-ext.streamx.cloud; '
                             'repeatable (default: $STREAMX_DELIVERY_URL)')
    parser.add_argument('--template', default='eds-pages', help='default: eds-pages')
    parser.add_argument('--query', default='streamx', help='default: streamx')
    parser.add_argument('--namespace', default='', help='only this namespace, e.g. en (default: all)')
    parser.add_argument('--minutes', type=float, default=45, help='stop after this long (default: 45)')
    parser.add_argument('--interval', type=float, default=0.5, help='seconds between searches (default: 0.5)')
    args = parser.parse_args(argv)

    edges = args.edge or ([os.environ['STREAMX_DELIVERY_URL']] if os.environ.get('STREAMX_DELIVERY_URL') else [])
    if not edges:
        parser.error('give --edge URL, or set STREAMX_DELIVERY_URL')
    watches = []
    for edge in edges:
        edge = edge.rstrip('/')
        if not edge.startswith('https://'):
            parser.error(f'--edge must be an https:// URL, not {edge!r}')
        params = {'query': args.query, 'size': '3'}
        if args.namespace:
            params['namespace'] = args.namespace
        # <project>.<cluster>.prod-ext...: the cluster names the edge.
        host = urllib.parse.urlsplit(edge).hostname.split('.')
        label = host[1] if len(host) > 2 else host[0]
        watches.append(Watch(label, search_url(edge, args.template, params)))

    width = max(len(w.name) for w in watches)
    for watch in watches:
        watch.name = watch.name.ljust(width)
    print(f'Watching {args.template} for {args.query!r} on {", ".join(w.name.strip() for w in watches)} '
          f'every {args.interval} s for up to {args.minutes:g} min. Ctrl-C to stop.\n', flush=True)
    return run(watches, args.minutes * 60, args.interval)


if __name__ == '__main__':
    sys.exit(main())
