#!/usr/bin/env bash
#
# Detect movement in the upstream StreamX connector action.
#
# Upstream `@v1` is a BRANCH, not a tag — that repository has no tags at all —
# so the thing every StreamX customer pins to can change under them without a
# version bump. Vendoring turns that from an invisible risk into a visible one:
# the exact upstream bytes this copy was taken from are committed under
# docs/upstream/, and this script says whether upstream still matches them.
#
# It deliberately does NOT diff upstream against our vendored copy. That diff is
# never empty — the deviations are intentional and documented in the action's
# README — so it would be ignored within a month. Comparing upstream against a
# snapshot of upstream is quiet until upstream actually moves, which is the only
# moment anyone needs to look.
#
# Usage: check-upstream-drift.sh [ref ...]     (default: v1 v2)
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
upstream_repo="streamx-hub/streamx-common-github-actions"
upstream_path=".github/actions/connector-github/action.yml"

refs=("$@")
[ "${#refs[@]}" -gt 0 ] || refs=(v1 v2)

work_dir="$(mktemp -d)"
trap 'rm -rf "$work_dir"' EXIT

drift=0
for ref in "${refs[@]}"; do
  snapshot="${repo_root}/docs/upstream/connector-github.${ref}.yml"
  if [ ! -f "$snapshot" ]; then
    echo "skip: no snapshot recorded for ${ref} (${snapshot#"$repo_root"/})"
    continue
  fi

  url="https://raw.githubusercontent.com/${upstream_repo}/${ref}/${upstream_path}"
  if ! curl --fail --silent --show-error --location \
            --retry 3 --retry-delay 2 --connect-timeout 15 --max-time 60 \
            --output "${work_dir}/${ref}.yml" "$url"; then
    echo "::warning::could not fetch ${url}; skipping the ${ref} comparison"
    continue
  fi

  if cmp -s "$snapshot" "${work_dir}/${ref}.yml"; then
    echo "ok:   upstream ${ref} is unchanged"
  else
    drift=1
    echo "::warning::upstream ${ref} has changed since this copy was vendored"
    echo "----- diff: recorded snapshot (-) vs upstream ${ref} now (+) -----"
    diff -u "$snapshot" "${work_dir}/${ref}.yml" || true
    echo "-------------------------------------------------------------------"
  fi
done

if [ "$drift" -ne 0 ]; then
  echo
  echo "Upstream moved. Review the diff above, decide whether the change matters to us,"
  echo "then either port it into .github/actions/connector-github/action.yml or not —"
  echo "and in both cases refresh the snapshot so this stays quiet until the next change:"
  echo
  echo "    curl -fsSL https://raw.githubusercontent.com/${upstream_repo}/v1/${upstream_path} \\"
  echo "      -o docs/upstream/connector-github.v1.yml"
  echo
  # A warning, not a failure: upstream moving is news, not a broken build.
  exit 0
fi
