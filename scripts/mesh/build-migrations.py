#!/usr/bin/env python3
"""Build service-init migrations from readable sources, and check them.

Painless scripts and search templates are unreadable once embedded as JSON
strings in an .http migration, so they live as plain files under mesh/sources/
and this script writes the migrations from them:

    python3 scripts/mesh/build-migrations.py build   # write the files in BUILDS
    python3 scripts/mesh/build-migrations.py check   # CI: committed files == a fresh build

Rules it enforces (docs/deploying.md, "Migrations"):
  - A migration that has run on the mesh is NEVER rewritten. Every applied file is
    pinned by sha256 in scripts/mesh/APPLIED.sha256; `build` refuses to change a
    pinned file and `check` fails if one changed. Pin a file in the PR after the one
    that deployed it.
  - No mustache tag inside painless embedded in a template, comments included:
    the template engine would parse it and the template would stop compiling.
  - Every built file is valid JSON after its request line.

Standard library only.
"""
from __future__ import annotations

import hashlib
import json
import os
import re
import sys

ROOT = os.path.normpath(os.path.join(os.path.dirname(os.path.abspath(__file__)), '..', '..'))
SI = os.path.join(ROOT, 'mesh', 'configs', 'opensearch', 'service-init')
SOURCES = os.path.join(ROOT, 'mesh', 'sources')
PINS = os.path.join(ROOT, 'scripts', 'mesh', 'APPLIED.sha256')


def painless(name: str) -> str:
    with open(os.path.join(SOURCES, 'painless', name + '.painless'), encoding='utf-8') as f:
        return f.read().rstrip('\n')


def read(*parts: str) -> str:
    with open(os.path.join(SOURCES, *parts), encoding='utf-8') as f:
        return f.read()


def http(request_line: str, body: dict) -> str:
    return f'{request_line}\nContent-Type: application/json\n\n{json.dumps(body, indent=2, ensure_ascii=False)}\n'


def mapping() -> str:
    return http('PUT /default/_mapping', json.loads(read('mappings', 'default-index-mapping.json')))


def pipeline() -> str:
    return http('PUT /_ingest/pipeline/default-local', {
        'description': 'Drop drafts, fragments, nav/footer, langstore and -copy pages; stamp '
                       'payload.ingested; turn the page <head> fields the producer extracted '
                       'into payload.description, payload.date and the search facet families.',
        'processors': [
            {'drop': {'tag': 'skip_page', 'if': painless('skip_page'), 'ignore_failure': True}},
            {'script': {'tag': 'stamp_ingested', 'lang': 'painless', 'ignore_failure': True,
                        'source': painless('stamp_ingested')}},
            {'script': {'tag': 'arbory_page_fields', 'lang': 'painless', 'ignore_failure': True,
                        'source': painless('arbory_page_fields')}},
        ],
    })


def template(template_id: str, source_file: str) -> str:
    text = read('templates', source_file)

    def embed(match):
        script = painless(match.group(1))
        if '{{' in script:
            raise SystemExit(f'{match.group(1)}.painless contains a mustache tag; it is embedded in a template')
        return json.dumps(script)[1:-1]
    text = re.sub(r'@@PAINLESS:([a-z_]+)@@', embed, text)
    return http(f'POST /_scripts/{template_id}', {'script': {'lang': 'mustache', 'source': text}})


# Migration file -> how to build it. Versions only ever go up; never reuse one.
BUILDS = {
    'V1.0.0.7.7__update_default_index_mapping.http': mapping,
    'V1.0.0.7.8__update_default_index_default_pipeline.http': pipeline,
    'V1.0.0.7.9__arbory_pages_search_template.http': lambda: template('arbory-pages', 'arbory-pages.mustache.json'),
}


def pins() -> dict[str, str]:
    out = {}
    if os.path.exists(PINS):
        for line in open(PINS, encoding='utf-8'):
            line = line.strip()
            if line and not line.startswith('#'):
                digest, name = line.split(None, 1)
                out[name.strip()] = digest
    return out


def sha(path: str) -> str:
    with open(path, 'rb') as f:
        return hashlib.sha256(f.read()).hexdigest()


def validate(name: str, text: str) -> None:
    head, _, body = text.partition('\n\n')
    if not re.match(r'^(PUT|POST) /\S+', head):
        raise SystemExit(f'{name}: no request line')
    json.loads(body)


def main(argv: list[str]) -> int:
    mode = argv[1] if len(argv) > 1 else 'check'
    pinned = pins()
    problems = []
    for name, digest in pinned.items():
        path = os.path.join(SI, name)
        if not os.path.exists(path):
            problems.append(f'{name}: pinned but missing')
        elif sha(path) != digest:
            problems.append(f'{name}: APPLIED migration changed; it will fail its checksum at sink startup')
    for name, build in BUILDS.items():
        text = build()
        validate(name, text)
        path = os.path.join(SI, name)
        current = open(path, encoding='utf-8').read() if os.path.exists(path) else None
        if current == text:
            print(f'  ok    {name}')
            continue
        if name in pinned:
            problems.append(f'{name}: sources changed, but the migration is applied; add a new version instead')
            continue
        if mode == 'build':
            with open(path, 'w', encoding='utf-8') as f:
                f.write(text)
            print(f'  wrote {name}')
        else:
            problems.append(f'{name}: out of date with mesh/sources (run build)')
    for p in problems:
        print(f'FAIL: {p}')
    return 1 if problems else 0


if __name__ == '__main__':
    sys.exit(main(sys.argv))
