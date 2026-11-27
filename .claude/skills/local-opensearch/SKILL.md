---
name: local-opensearch
description: Run and test search templates, painless pipelines, mappings and service-init migrations against a local OpenSearch kept in .local/ (gitignored). Use before changing anything under mesh/sources/ or mesh/configs/opensearch/, before running scripts/mesh/test_search_local.py, or whenever a query, aggregation or template needs trying on real pages. If the local OpenSearch is not installed, offer to install it.
---

# Local OpenSearch for arbory-streamx

The production mesh exposes only named search templates; there is no `_search`,
`_mapping` or admin API to try things on (see docs/debugging-the-mesh.md). A
template or painless error found on the mesh costs a redeploy and ~30 s of 503s.
So every template, pipeline and mapping change is tried on a local OpenSearch
first. Everyone keeps it in the same place, managed by one script:

| | |
|---|---|
| Script | `scripts/mesh/local-opensearch.sh install \| start \| stop \| status \| logs` |
| Install | `.local/opensearch-2.16.0/` (gitignored, ~1.3 GB unpacked) |
| Data | `.local/opensearch-data/` (survives a reinstall) |
| URL | `http://127.0.0.1:9200`, single node, security off, loopback only |

## Steps

1. Run `scripts/mesh/local-opensearch.sh status`.
2. **Not installed** (no `.local/opensearch-2.16.0/bin/opensearch`): ask the user before
   installing. Tell them it downloads `opensearch-2.16.0-linux-x64.tar.gz` (~900 MB)
   from artifacts.opensearch.org, checks it against the published sha512, and unpacks
   it into `.local/` in this repo. On a yes, run `scripts/mesh/local-opensearch.sh install`
   in the background (it takes a few minutes). On a no, don't change templates blind:
   say the change is untested and stop short of opening a PR.
3. **Installed but not running**: `scripts/mesh/local-opensearch.sh start` (waits for
   green, ~20 s). Leave it running for the session; `stop` when done.
4. Run the end-to-end check, which rebuilds the `default` index from every migration
   and indexes real pages:
   `python3 scripts/mesh/test_search_local.py` (`--pages`, `--de-pages` to widen it).
5. To try a new template before it is a migration, PUT it straight in:
   `curl -s -XPUT localhost:9200/_scripts/<id> -H 'Content-Type: application/json' -d '{"script":{"lang":"mustache","source":<template>}}'`
   then `POST localhost:9200/default/_search/template` with `{"id": "<id>", "params": {...}}`.
   Send params as **lowercased strings**: that is how opensearch-sink forwards them.
6. When it works, add the source under `mesh/sources/`, register it in
   `scripts/mesh/build-migrations.py` `BUILDS`, run `build`, and add assertions to
   `test_search_local.py` so the next change keeps it working.

## Notes

- `test_search_local.py` refuses any host but localhost and deletes the `default`
  index each run. Never point either script at the mesh.
- Linux x64 only (the tarball bundles its own JDK). On a Mac, run OpenSearch 2.16 any
  way you like on 127.0.0.1:9200 with security off; the test script only needs the URL.
- Another version: `OPENSEARCH_VERSION=2.x.y scripts/mesh/local-opensearch.sh install`.
  Match what the mesh's opensearch-sink runs.
