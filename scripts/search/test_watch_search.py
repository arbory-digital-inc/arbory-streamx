#!/usr/bin/env python3
"""Tests for watch_search.py. Standard library only; no network.

    python3 scripts/search/test_watch_search.py
"""
from __future__ import annotations

import contextlib
import io
import os
import sys
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import watch_search as w  # noqa: E402


def body(*pairs):
    return {'hits': {'hits': [{'_id': i, '_score': s} for i, s in pairs]}}


class Record(unittest.TestCase):
    def test_a_restart(self):
        watch = w.Watch('dev', 'u')
        old, new = 'en:/a 5.0', 'en:/hub 12.3'
        self.assertIn('ranking', watch.record(0.0, True, old))
        self.assertIsNone(watch.record(0.5, True, old))
        self.assertIn('FAILING', watch.record(1.0, False, 'HTTP 503'))
        self.assertIsNone(watch.record(1.5, False, 'HTTP 503'))
        line = watch.record(9.0, True, new)
        self.assertIn('back     after 8.0 s', line)
        self.assertIn('CHANGED', line)
        self.assertEqual((watch.sent, watch.failed), (5, 2))
        summary = watch.summary(10.0)
        self.assertIn('5 searches, 2 failed, longest outage 8.0 s', summary)
        self.assertIn('ranking changed at', summary)

    def test_an_outage_still_open_at_the_end_counts(self):
        watch = w.Watch('edge-b', 'u')
        watch.record(0.0, True, 'x')
        watch.record(1.0, False, 'timeout')
        summary = watch.summary(4.0)
        self.assertIn('longest outage 3.0 s', summary)
        self.assertIn('STILL FAILING', summary)
        self.assertIn('ranking never changed', summary)

    def test_fingerprint(self):
        self.assertEqual(w.fingerprint(body(('a', 5.0), ('b', 4.0), ('c', 3.0), ('d', 1.0))),
                         'a 5.0, b 4.0, c 3.0')
        self.assertEqual(w.fingerprint({'hits': {'hits': []}}), '(no hits)')

    def test_the_two_replicas_give_one_fingerprint(self):
        # Measured 2026-10-13: the same top three, scored by each of two replicas.
        one = body(('tn', 19.321938), ('nyc', 19.134233), ('co', 18.966993))
        two = body(('tn', 19.324108), ('nyc', 19.13619), ('co', 18.972216))
        self.assertEqual(w.fingerprint(one), w.fingerprint(two))


class Run(unittest.TestCase):
    def watch(self, names, answers, seconds=4):
        """run() on a fake clock that only sleep() moves, one edge per name."""
        clock = [0.0]

        def fetch(url):
            answer = answers[url].pop(0) if answers[url] else body(('hub', 9.1))
            if isinstance(answer, Exception):
                raise answer
            return answer

        def sleep(seconds):
            clock[0] += seconds

        out, original = io.StringIO(), w.now
        w.now = lambda: clock[0]
        try:
            watches = [w.Watch(n, n) for n in names]
            w.run(watches, seconds=seconds, interval=0.5, out=out, fetch=fetch, sleep=sleep)
        finally:
            w.now = original
        return watches, out.getvalue()

    def test_one_restart(self):
        answers = {'lax': [body(('a', 5.0))] * 2 + [w.SearchError('HTTP 503')] * 3}
        (lax,), text = self.watch(['lax'], answers)
        self.assertIn('lax       FAILING  HTTP 503', text)
        self.assertIn('lax       back     after 1.5 s', text)
        self.assertIn('lax       CHANGED  hub 9.1', text)
        self.assertEqual((lax.sent, lax.failed), (8, 3))

    def test_every_edge_gets_a_summary(self):
        _, text = self.watch(['lax', 'bhs'], {'lax': [], 'bhs': []}, seconds=1)
        last = text.splitlines()[-2:]
        self.assertTrue(last[0].startswith('lax') and last[1].startswith('bhs'), last)


class Main(unittest.TestCase):
    def test_needs_an_edge(self):
        saved = os.environ.pop('STREAMX_DELIVERY_URL', None)
        try:
            with self.assertRaises(SystemExit), contextlib.redirect_stderr(io.StringIO()):
                w.main([])
        finally:
            if saved is not None:
                os.environ['STREAMX_DELIVERY_URL'] = saved

    def test_labels_are_cluster_names(self):
        seen = []
        original = w.run
        w.run = lambda watches, *a, **k: seen.extend(watches) or 0
        try:
            with contextlib.redirect_stdout(io.StringIO()):
                w.main(['--edge', 'https://so-x-1.eu-south-mil-edge.prod-ext.streamx.cloud/',
                        '--edge', 'https://so-x-1.ap-southeast-sin-edge.prod-ext.streamx.cloud',
                        '--namespace', 'en'])
        finally:
            w.run = original
        self.assertEqual([x.name.strip() for x in seen], ['eu-south-mil-edge', 'ap-southeast-sin-edge'])
        self.assertIn('/search/eds-pages/?query=streamx&size=3&namespace=en', seen[0].url)


if __name__ == '__main__':
    unittest.main(verbosity=1)
