# StreamX GitHub connector action (internalized)

An internalized copy of
[`streamx-hub/streamx-common-github-actions/.github/actions/connector-github@v1`](https://github.com/streamx-hub/streamx-common-github-actions/tree/v1/.github/actions/connector-github),
carrying **no third-party action references**, so it runs in an organization whose
GitHub Actions allow-list is set to *enterprise-owned + GitHub-authored +
Marketplace-verified*.

## Why

Calling the upstream action from such an org fails before a single step runs:

```
The action streamx-hub/streamx-common-github-actions/.github/actions/connector-github@v1
is not allowed in <customer-org>/<customer-repo> because all actions must be from a repository owned
by your enterprise, created by GitHub, or verified in the GitHub Marketplace.
```

Nothing about the action is wrong — it is simply owned by someone outside the
enterprise. Copying it into a repository the enterprise owns removes the
objection. Doing that is only useful if the copy is *itself* clean, which is the
constraint this directory exists to hold: **every step is plain bash or an
action from the GitHub-authored `actions/*` org.**

## How to use it

The input surface is identical to upstream, so migrating a workflow is a
one-line change:

```diff
-        uses: streamx-hub/streamx-common-github-actions/.github/actions/connector-github@v1
+        uses: arbory-digital-inc/arbory-streamx/.github/actions/connector-github@v1
```

See the upstream README for what the inputs mean and the ingestion-source
providers; that documentation is not duplicated here, because duplicating it is
how it goes stale.

Two consumption modes, both supported:

| Mode | Reference | Needs |
| --- | --- | --- |
| **Cross-repo** | `uses: <org>/<streamx-repo>/.github/actions/connector-github@v1` | The action repo readable by the caller. For a **private or internal** action repo that means *Settings → Actions → General → Access → "Accessible from repositories in the `<org>` organization"* — without it the caller gets a "repository not found" style failure. |
| **Path-vendored** | `uses: ./.github/actions/connector-github` | The files copied into the consuming repo (`scripts/vendor/sync-connector-action.sh`) **and** an `actions/checkout` step before the action runs — a local action that has not been checked out does not exist. |

Cross-repo is the better default: one copy, one place to bump. Path-vendoring is
the fallback for when cross-repo access cannot be granted.

## What was changed, and why

| Upstream v1 | Here | Reason |
| --- | --- | --- |
| `uses: jbangdev/setup-jbang@main` | `install-jbang.sh` | The reference the allow-list rejects. Upstream's action runs `curl -Ls https://sh.jbang.dev \| bash -s - app setup` and installs whatever "latest" is; the replacement fetches one pinned release asset and refuses it unless it matches a recorded SHA-256. |
| `actions/setup-java@v3`, `distribution: adopt` | `@v6`, `distribution: temurin` | Both deprecated; every upstream run emits a warning for each. Upstream's own `v2` branch has already moved to `temurin`. |
| `jbang jdk install 21 ${{ env.JAVA_HOME_21_X64 }}` | `${JAVA_HOME_21_X64:-$JAVA_HOME}` | `JAVA_HOME_21_X64` is set only by `setup-java` on an x64 runner. On arm64, or a self-hosted runner with a pre-provisioned JDK, it is empty and the JDK link silently does nothing — costing a ~200MB JDK download inside JBang. `$JAVA_HOME` is set in all of those cases. |
| cache key `hashFiles('.jbang/cache/dependency_cache.json')` | `${{ runner.os }}-m2-streamx-connector-<version>` | That path only ever exists under `$HOME`, never in the consuming repo's workspace, so `hashFiles` always returned empty and the key was a constant. Naming the connector version makes the constant honest: a version bump gets a fresh cache instead of inheriting the previous version's. |
| no `description` | `description:` set | Required for any action published or linted; harmless otherwise. |

Everything else — all twelve inputs, the `settings.xml` snapshot handling, the
`jbang` invocation, the `JSON_INPUTS` contract and the error-counting exit
logic — is byte-for-byte upstream. Deliberately: the smaller the diff, the
easier it is to tell a vendoring bug from a connector bug.

### Do not add inputs

`${{ toJSON(inputs) }}` is handed to the connector as `JSON_INPUTS`. Anything
declared in `inputs:` lands in the connector's configuration whether it belongs
there or not. Knobs that are ours rather than the connector's are pinned as
step-level `env:` in `action.yml`.

## Bumping the pins

**JBang.** Pick a version, take its checksum from the release's own manifest,
and put both in the `Install JBang` step of `action.yml`:

```bash
curl -fsSL https://github.com/jbangdev/jbang/releases/download/v0.141.0/checksums_sha256.txt \
  | grep -E '  jbang-0\.141\.0\.tar$'
```

Use the plain `jbang-<version>.tar` asset. The `-linux-x64` variants bundle a
JDK the runner already has, and `.tar` avoids depending on `unzip` being
installed.

**The connector.** `com.streamx:streamx-github-connector:<version>` appears
twice in `action.yml` — the `jbang` command line and the cache key.
`scripts/vendor/check-allowlist-safety.sh` fails the build if the two drift
apart.

## Upstream drift

Upstream `@v1` is a **branch, not a tag** — it moves. There are no tags in that
repository at all. To see what has changed since this copy was taken:

```bash
gh api repos/streamx-hub/streamx-common-github-actions/contents/.github/actions/connector-github/action.yml?ref=v1 \
  --jq .content | base64 -d | diff - .github/actions/connector-github/action.yml
```

The diff will always show the deviations in the table above; read past those.
Upstream's `v2` branch differs from `v1` only in the `temurin` switch and in
dropping the JDK-link step, both of which this copy already accounts for.
