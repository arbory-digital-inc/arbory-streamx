#!/usr/bin/env python3
"""End-to-end check of the service-init migrations against a REAL OpenSearch.

The migrations' interesting content is painless and mustache inside JSON strings,
and a painless compile error only surfaces when the sink PUTs the pipeline at
startup, where a failure blocks every later migration and takes search down.
This runs that startup on a throwaway local OpenSearch first:

  1. creates an empty `default` index and applies every migration in version
     order, exactly as the sink does (a failure here is a failure there);
  2. indexes real pages through the `default-local` pipeline, shaped the way the
     producer emits them (payload.facets.<key>_level0/_hierarchy/_path);
  3. runs the search page's request bodies through the `arbory-pages` template
     and asserts on the results, facets, sort and filters.

    # a single-node OpenSearch 2.16 on localhost:9200 with security disabled, then
    python3 scripts/mesh/test_search_local.py [--opensearch http://localhost:9200]
        [--site https://main--arbory-da--arbory-digital-inc.aem.live] [--pages 60]
        [--www-site https://main--arbory-www--arbory-digital-inc.aem.live]

DESTRUCTIVE to the target: it deletes and recreates the index `default`. It
refuses any host but localhost. Standard library only.
"""
from __future__ import annotations

import argparse
import html
import json
import os
import re
import sys
import urllib.error
import urllib.parse
import urllib.request

ROOT = os.path.normpath(os.path.join(os.path.dirname(os.path.abspath(__file__)), '..', '..'))
SI = os.path.join(ROOT, 'mesh', 'configs', 'opensearch', 'service-init')
FAILURES: list[str] = []

# Last migration that was live before this change (V1.0.0.7.6).
LEGACY_UNTIL = [1, 0, 0, 7, 6]
LEGACY_DOCS = [
    {'type': 'page/eds', 'namespace': 'en',
     'payload': {'title': 'legacy', 'content': 'legacy page aem',
                 'facets': {'searchtags': 'Arbory Display | Content type / Blogs, Arbory Display | tags / AEM',
                            'tags_level0': 'AEM,AEM 6.5,CMS', 'content_type_level0': 'Blogs',
                            'category_hierarchy': ['Blogs', 'Content type>Blogs'],
                            'categories_level0': 'AEM News'}},
     'fragments': []},
    {'type': 'page/eds', 'namespace': 'zh-cn',
     'payload': {'title': 'legacy 2', 'content': 'legacy', 'facets': {}}, 'fragments': []},
]


def call(base, method, path, body=None):
    data = None if body is None else (body if isinstance(body, bytes) else json.dumps(body).encode())
    req = urllib.request.Request(base + path, data=data, method=method,
                                 headers={'Content-Type': 'application/json'})
    try:
        with urllib.request.urlopen(req, timeout=60) as r:
            return r.status, json.loads(r.read() or b'{}')
    except urllib.error.HTTPError as e:
        return e.code, json.loads(e.read() or b'{}')


def check(ok, what):
    print(f'  {"ok  " if ok else "FAIL"}  {what}')
    if not ok:
        FAILURES.append(what)


def version_key(name):
    return [int(x) for x in re.match(r'V([\d.]+)__', name).group(1).split('.')]


def migrations():
    names = sorted((n for n in os.listdir(SI) if n.endswith('.http')), key=version_key)
    for name in names:
        text = open(os.path.join(SI, name), encoding='utf-8').read()
        head, _, body = text.partition('\n\n')
        method, path = head.splitlines()[0].split(None, 1)
        yield name, method, '/' + path.lstrip('/'), body.strip()


def get(url):
    req = urllib.request.Request(url, headers={'User-Agent': 'arbory-streamx-test/1.0'})
    with urllib.request.urlopen(req, timeout=30) as r:
        return r.read().decode('utf-8', 'replace')


def producer_doc(path, page_html, namespace='en'):
    """The document the producer would emit for this page (the fields we use)."""
    metas = re.findall(r'<meta\s+([^>]*)>', page_html)

    def attrs(m):
        return {k: html.unescape(v) for k, v in re.findall(r'([\w:-]+)="([^"]*)"', m)}
    named, tags = {}, []
    for m in metas:
        a = attrs(m)
        if a.get('property') == 'article:tag':
            tags.append(a.get('content', ''))
        elif a.get('name') in ('description', 'date', 'category', 'author'):
            named[a['name']] = a.get('content', '')
    facets = {}

    def put(key, value):
        value = value.strip()
        facets[f'{key}_level0'] = value
        facets[f'{key}_hierarchy'] = [value]
        facets[f'{key}_path'] = value
    for k, v in named.items():
        put(k, v)
    for i, t in enumerate(tags[:16], 1):
        put(f'tag{i}', t)
    title = re.search(r'<title>(.*?)</title>', page_html, re.S)
    body = re.sub(r'<[^>]+>', ' ', re.sub(r'(?s)<(script|style|head)\b.*?</\1>', ' ', page_html))
    return {
        'type': 'page/eds', 'namespace': namespace,
        'payload': {'title': html.unescape(title.group(1).strip()) if title else '',
                    'content': re.sub(r'\s+', ' ', html.unescape(body)).strip()[:20000],
                    'facets': facets},
        'fragments': [],
    }


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__.split('\n\n')[0])
    ap.add_argument('--opensearch', default='http://localhost:9200')
    ap.add_argument('--site', default='https://main--arbory-da--arbory-digital-inc.aem.live')
    ap.add_argument('--pages', type=int, default=60)
    ap.add_argument('--www-site', default='https://main--arbory-www--arbory-digital-inc.aem.live',
                    help='the apex site, indexed alongside the blog as en://arborydigital.com/<path>')
    args = ap.parse_args(argv)
    base = args.opensearch.rstrip('/')
    if urllib.parse.urlsplit(base).hostname not in ('localhost', '127.0.0.1'):
        ap.error('refusing a non-local OpenSearch: this deletes the index `default`')

    print('Fresh index, then every migration in version order:')
    call(base, 'DELETE', '/default')
    status, _ = call(base, 'PUT', '/default', {'mappings': {'properties': {'fragments': {'type': 'nested'}}}})
    check(status == 200, 'created index default')
    legacy_done = False
    for name, method, path, body in migrations():
        if not legacy_done and version_key(name) > LEGACY_UNTIL:
            # The live index was built by the earlier pipelines, so its dynamic
            # mappings already exist when the new migrations run. Recreate that:
            # documents shaped like the ones on the mesh on 2026-11-25, indexed
            # through the pipeline that was live then. A new mapping that conflicts
            # with a dynamic one fails here exactly as it would at sink startup.
            for i, legacy in enumerate(LEGACY_DOCS):
                status, resp = call(base, 'PUT', f'/default/_doc/legacy-{i}?refresh=true', legacy)
                check(status in (200, 201), f'legacy document {i} indexed through the old pipeline')
            legacy_done = True
        status, resp = call(base, method, path, body.encode() if body else None)
        check(status in (200, 201), f'{name} -> {status} {"" if status < 300 else json.dumps(resp)[:300]}')
    for i in range(len(LEGACY_DOCS)):
        call(base, 'DELETE', f'/default/_doc/legacy-{i}')

    print('Index real pages through default-local:')
    index = json.loads(get(args.site + '/en-index.json?limit=1000'))['data']
    paths = [r['path'] for r in index if '/blog/' in r['path'] or '/podcast/' in r['path']][:args.pages]
    paths += [r['path'] for r in index if '/customer-stories/' in r['path'] or '/events/' in r['path']][:3]
    skipped = ['/en/nav', '/en/footer', '/en/fragments/bios/tad-reeves', '/en/drafts/x', '/en/blog/x-copy',
               '/en/search', '/en/taglist']
    for path in paths + skipped:
        try:
            page = get(args.site + path) if path not in skipped else '<title>skip me</title>'
        except Exception as e:  # a page can 404 between index and fetch
            print(f'  skip  {path}: {e}')
            continue
        doc_id = urllib.parse.quote(f'en:{path}', safe='')
        status, resp = call(base, 'PUT', f'/default/_doc/{doc_id}?refresh=false', producer_doc(path, page))
        if status not in (200, 201):
            check(False, f'index {path} -> {status} {json.dumps(resp)[:200]}')
    call(base, 'POST', '/default/_refresh')

    for path in skipped:
        status, _ = call(base, 'GET', '/default/_doc/' + urllib.parse.quote(f'en:{path}', safe=''))
        check(status == 404, f'dropped by skip_page: {path}')

    print('Index the apex site alongside, keyed by protocol-relative URL:')
    www_host = '//arborydigital.com'
    www_pages = {'/en/services/aem-upgrades': 'Page', '/en/about/meet-the-team': 'Page',
                 '/en/customer-stories/jmp-customer-spotlight': 'Customer story', '/en/index': 'Page'}
    www_skipped = ['/en/fragments/nav/header', '/en/nav', '/en/search', '/en/services/aem-upgrades-copy']
    for path in list(www_pages) + www_skipped:
        try:
            page = get(args.www_site + path.replace('/index', '/')) if path in www_pages else '<title>skip me</title>'
        except Exception as e:
            check(False, f'fetch {args.www_site}{path}: {e}')
            continue
        doc_id = urllib.parse.quote(f'en:{www_host}{path}', safe='')
        status, resp = call(base, 'PUT', f'/default/_doc/{doc_id}?refresh=true', producer_doc(path, page))
        check(status in (200, 201), f'index en:{www_host}{path} -> {status}')
    for path in www_skipped:
        status, _ = call(base, 'GET', '/default/_doc/' + urllib.parse.quote(f'en:{www_host}{path}', safe=''))
        check(status == 404, f'dropped by skip_page: en:{www_host}{path}')
    for path, want in www_pages.items():
        status, resp = call(base, 'GET', '/default/_doc/' + urllib.parse.quote(f'en:{www_host}{path}', safe=''))
        got = resp.get('_source', {}).get('payload', {}).get('facets', {}).get('content_type_level0') if status == 200 else None
        check(got == [want], f'en:{www_host}{path} content type {got} == [{want!r}]')

    status, resp = call(base, 'POST', '/default/_search', {'size': 500, 'query': {'match_all': {}}})
    docs = {h['_id']: h['_source'] for h in resp['hits']['hits']}
    check(len(docs) >= len(paths) - 5, f'{len(docs)} documents indexed')
    facets_seen = {}
    for src in docs.values():
        for k, v in src['payload'].get('facets', {}).items():
            facets_seen.setdefault(k, 0)
            facets_seen[k] += 1
    print('  facet fields on indexed docs:', facets_seen)
    check(set(facets_seen) <= {'content_type_level0', 'topic_level0', 'technology_level0', 'year_level0',
                               'author_level0', 'category_hierarchy'}, 'no raw producer keys survive in payload.facets')
    check(facets_seen.get('content_type_level0', 0) == len(docs), 'every document has a content type')
    dated = [s['payload']['date'] for s in docs.values() if s['payload'].get('date')]
    check(len(dated) >= len(docs) * 0.6, f'{len(dated)}/{len(docs)} documents carry payload.date')
    check(all(re.fullmatch(r'\d{4}-\d\d-\d\d', d) for d in dated), 'every payload.date is yyyy-MM-dd')
    check(sum(1 for s in docs.values() if s['payload'].get('description')) >= len(docs) * 0.6,
          'most documents carry payload.description')
    check(all('ingested' in s['payload'] for s in docs.values()), 'every document is stamped payload.ingested')

    def search(params):
        status, resp = call(base, 'POST', '/default/_search/template', {'id': 'arbory-pages', 'params': params})
        if status != 200:
            check(False, f'search {json.dumps(params)[:120]} -> {status} {json.dumps(resp)[:300]}')
            return None
        return resp

    print('The search page\'s requests through arbory-pages:')
    r = search({'query': 'aem', 'namespace': 'en', 'from': 0, 'size': 10})
    if r:
        check(r['hits']['total']['value'] > 0, f'query aem: {r["hits"]["total"]["value"]} hits')
        aggs = r.get('aggregations', {})
        check(set(aggs) >= {'content_type_level0', 'topic_level0', 'technology_level0', 'year_level0', 'author_level0'},
              f'aggregations: {sorted(aggs)}')
        for name, agg in aggs.items():
            print(f'    {name}: {[(b["key"], b["doc_count"]) for b in agg["buckets"][:8]]}')
        src = r['hits']['hits'][0]['_source']
        check('facets' in src['payload'] and list(src['payload']['facets']) == ['content_type_level0'],
              f'_source projects only payload.facets.content_type_level0: {list(src["payload"].get("facets", {}))}')
        check('content' not in src['payload'], '_source does not carry payload.content')
    r = search({'query': 'aem', 'namespace': 'en', 'size': 50, 'sort': 'date:desc'})
    if r:
        ds = [h['_source']['payload'].get('date') for h in r['hits']['hits']]
        dated = [d for d in ds if d]
        check(dated == sorted(dated, reverse=True), 'sort date:desc orders by date')
        check(ds.index(None) >= len(dated) if None in ds else True, 'undated documents sort last')
    r = search({'query': 'aem', 'namespace': 'en', 'size': 50,
                'filter_query': {'fields': [{'name': 'category_hierarchy', 'values': ['Podcast'], 'last': True}]}})
    if r:
        types = {h['_source']['payload']['facets']['content_type_level0'][0] for h in r['hits']['hits']}
        check(r['hits']['total']['value'] > 0 and types == {'Podcast'}, f'filter Podcast -> types {types}')
    r = search({'query': 'edge delivery', 'namespace': 'en', 'size': 5,
                'operators': {'any_of': [{'all_of': [{'text': 'edge', 'last_term': False},
                                                     {'text': 'delivery', 'last_term': True}], 'last_group': True}]}})
    if r:
        check(r['hits']['total']['value'] > 0, f'operators AND: {r["hits"]["total"]["value"]} hits')
    r = search({'query': 'upgrades', 'namespace': 'en', 'size': 50})
    if r:
        ids = [h['_id'] for h in r['hits']['hits']]
        check(f'en:{www_host}/en/services/aem-upgrades' in ids, 'the en namespace answers with apex-site pages too')
        check(any(i.startswith('en:/en/') for i in ids), 'and with blog pages, in the same result list')
    r = search({'query': 'upgrades', 'namespace': 'en', 'size': 50,
                'filter_query': {'fields': [{'name': 'category_hierarchy', 'values': ['Customer story'], 'last': True}]}})
    if r:
        check(all(h['_source']['payload']['facets']['content_type_level0'] == ['Customer story'] for h in r['hits']['hits']),
              'filter Customer story keeps both sites\' customer stories only')
    r = search({'query': 'zzqqxxnotaword', 'namespace': 'en'})
    if r:
        check(r['hits']['total']['value'] == 0, 'nonsense query returns nothing')
    status, resp = call(base, 'GET', '/_search/template', None)
    status, resp = call(base, 'POST', '/default/_search/template',
                        {'id': 'pages', 'params': {'query': 'aem', 'namespace': 'en', 'size': 8}})
    check(status == 200 and resp['hits']['total']['value'] > 0, 'suggestions template `pages` still answers')
    status, resp = call(base, 'POST', '/default/_search/template',
                        {'id': 'eds-pages', 'params': {'query': 'aem', 'size': 5}})
    check(status == 200 and all('ingested' in h['_source']['payload'] for h in resp['hits']['hits']),
          'eds-pages (verify-indexed) still projects payload.ingested')

    print()
    print('FAILED: ' + '; '.join(FAILURES) if FAILURES else 'All checks passed.')
    return 1 if FAILURES else 0


if __name__ == '__main__':
    sys.exit(main())
