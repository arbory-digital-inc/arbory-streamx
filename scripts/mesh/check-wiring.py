#!/usr/bin/env python3
"""Assert every channel in the mesh has both a producer and a consumer.

WHY THIS EXISTS
---------------
On 2026-09-06 a mesh restructure re-pointed a consumer at `relay.pages`, a channel
nothing wrote to, and left `inbox.pages` — where the ingestion source actually
writes — with no consumer at all. Publishes were accepted and silently discarded
for two and a half hours. Nothing failed: every service was healthy, every
workflow run was green, and a channel with no subscriber reports zero backlog, so
the console showed zeros everywhere.

The defect was visible in mesh.yaml the whole time. It is a graph with a hole in
it, and a graph with a hole in it can be checked by a machine in about a second.
That is all this does.

Two failure shapes, both real that day:

  consumed, never produced   a service subscribed to a channel nobody writes.
                             It will sit idle forever, logging nothing.

  produced, never consumed   messages written into a channel nobody reads.
                             They are dropped, and nothing reports it.

Accepted orphans go in mesh/.wiring-allow-orphans, one channel per line, so that
a deliberate dead end is written down rather than argued about at 2am.

Usage: check-wiring.py [path/to/mesh.yaml]
"""
import re
import sys
from pathlib import Path

SECTION = re.compile(r'^  ([a-z0-9-]+):\n(.*?)(?=^  [a-z0-9-]+:|\Z)', re.S | re.M)
BLOCK_END = r'(?=outgoing:|incoming:|environment|volumesFrom|servicePorts|autoRef|environmentFrom|descriptor:|\Z)'
REF = re.compile(r'ref:\s*(\S+)')


def refs(body: str, keyword: str) -> list[str]:
    out = []
    for block in re.findall(keyword + r':(.*?)' + BLOCK_END, body, re.S):
        out += REF.findall(block)
    return out


def main() -> int:
    mesh_path = Path(sys.argv[1] if len(sys.argv) > 1 else 'mesh/mesh.yaml')
    if not mesh_path.is_file():
        print(f'FAIL: no mesh file at {mesh_path}', file=sys.stderr)
        return 1
    text = mesh_path.read_text()

    allow_path = mesh_path.parent / '.wiring-allow-orphans'
    allowed = set()
    if allow_path.is_file():
        for line in allow_path.read_text().splitlines():
            line = line.split('#', 1)[0].strip()
            if line:
                allowed.add(line)

    producers: dict[str, list[str]] = {}
    consumers: dict[str, list[str]] = {}

    # `sources:` declare outgoing refs the same way services do, and they are the
    # entry point of the whole graph — miss them and every inbox channel looks
    # like an orphan.
    for name, body in SECTION.findall(text):
        for ch in refs(body, 'outgoing'):
            producers.setdefault(ch, []).append(name)
        for ch in refs(body, 'incoming'):
            consumers.setdefault(ch, []).append(name)

    channels = sorted(set(producers) | set(consumers))
    if not channels:
        print('FAIL: no channel refs found — has the mesh file format changed?', file=sys.stderr)
        return 1

    width = max(len(c) for c in channels)
    problems = []

    print(f'{mesh_path}: {len(channels)} channels\n')
    for ch in channels:
        p = producers.get(ch, [])
        c = consumers.get(ch, [])
        if p and c:
            mark = 'ok  '
        elif ch in allowed:
            mark = 'skip'
        else:
            mark = 'FAIL'
            problems.append(
                (ch, 'consumed but never produced' if c else 'produced but never consumed')
            )
        print(f'  {mark}  {ch:<{width}}  produced by {p or ["-"]}  consumed by {c or ["-"]}')

    if problems:
        print()
        for ch, why in problems:
            print(f'FAIL: {ch} is {why}.', file=sys.stderr)
        print(
            '\nA channel with only one end silently drops every message that reaches it,\n'
            'and reports no backlog while doing so. If one of these is deliberate, add it\n'
            f'to {allow_path} with a comment saying why.',
            file=sys.stderr,
        )
        return 1

    print('\nEvery channel has a producer and a consumer.')
    return 0


if __name__ == '__main__':
    sys.exit(main())
