# arbory-streamx

StreamX configuration for Arbory sites — the mesh definition, the OpenSearch
index and search-template migrations, and the GitHub Actions that publish into it.

| | |
| --- | --- |
| [docs/debugging-the-mesh.md](docs/debugging-the-mesh.md) | **Start here when pages are published but not searchable.** Three-minute triage, the chain map, and the failure modes that report themselves as healthy. |
| [.github/actions/connector-github](.github/actions/connector-github/README.md) | Internalized StreamX connector action — no third-party actions, so it runs under a restrictive actions allow-list. |
| [.github/actions/verify-indexed](.github/actions/verify-indexed/README.md) | Asserts a document actually reached the search index, rather than that the API accepted the event. |
| `mesh/` | Mesh definition, service configs, and `service-init` migrations (run at sink startup, in version order). |
| `scripts/vendor/` | Guards and sync tooling for the vendored actions. |
| `scripts/reindex/` | Rebuild an index by re-publishing a site. |

Note that merges to `main` trigger a mesh redeploy — this repository is the
config source for the deployed mesh.
