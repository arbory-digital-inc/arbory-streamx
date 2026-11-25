# arbory-streamx

StreamX configuration for Arbory sites — the mesh definition, the OpenSearch
index and search-template migrations, and the GitHub Actions that publish into it.

| | |
| --- | --- |
| [docs/debugging-the-mesh.md](docs/debugging-the-mesh.md) | **Start here when pages are published but not searchable.** Three-minute triage, the chain map, and the failure modes that report themselves as healthy. |
| [docs/deploying.md](docs/deploying.md) | **Read before merging anything.** What a merge rolls and what it costs readers, hostnames as cluster names, the console's own commits to this repo, moving a mesh between regions, replicas and sizing, stalled rollouts, migrations, secrets and tokens. |
| [.github/actions/connector-github](.github/actions/connector-github/README.md) | Internalized StreamX connector action — no third-party actions, so it runs under a restrictive actions allow-list. |
| [.github/actions/verify-indexed](.github/actions/verify-indexed/README.md) | Asserts a document actually reached the search index, rather than that the API accepted the event. |
| `mesh/` | Mesh definition, service configs, and `service-init` migrations (run at sink startup, in version order). |
| `scripts/vendor/` | Guards and sync tooling for the vendored actions. |
| `scripts/reindex/` | Rebuild an index by re-publishing a site. |
| `mesh/sources/`, `scripts/mesh/build-migrations.py` | Readable sources (painless, search templates, mappings) for the `service-init` migrations, and the builder that writes them; `test_search_local.py` runs every migration against a local OpenSearch and exercises the search page's requests. |
| `scripts/search/watch_search.py` | Watch search on one or more edges through a deploy or a region move; reports each edge's longest outage. |

Note that merges to `main` trigger a mesh redeploy — this repository is the
config source for the deployed mesh. The StreamX console also commits here
(`Update mesh/cloud-config.yaml`), so pull before you branch.
