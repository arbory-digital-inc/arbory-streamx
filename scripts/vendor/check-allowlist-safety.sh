#!/usr/bin/env bash
#
# Assert that a vendored action stays usable under a GitHub Actions allow-list
# restricted to "enterprise-owned, GitHub-authored, or Marketplace-verified".
#
# The whole value of vendoring these actions is one invariant: nothing in them
# references a third-party action. That invariant is invisible — a single
# well-meaning `uses: some/handy-action@v2` reintroduces the original failure,
# and it will not fail in the repo that holds the action. It will fail in the
# consuming repo, at publish time, in someone else's org.
#
# So it is checked mechanically. Run it in CI in every repo that hosts a copy.
#
# Universal checks run against any action directory. The connector-specific
# checks run only where a connector is found, so this one script can guard every
# action in the family.
#
# Usage: check-allowlist-safety.sh [action-dir ...]
#        with no arguments, checks every action under .github/actions/
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Resolves in both homes this script has: next to the action after being vendored
# into a consuming repo, or under scripts/vendor/ in the repo that owns it.
if [ "$#" -gt 0 ]; then
  action_dirs=("$@")
elif [ -f "${script_dir}/action.yml" ]; then
  action_dirs=("$script_dir")
else
  repo_root="$(cd "${script_dir}/../.." && pwd)"
  action_dirs=()
  for d in "${repo_root}"/.github/actions/*/; do
    [ -f "${d}action.yml" ] && action_dirs+=("${d%/}")
  done
  [ "${#action_dirs[@]}" -gt 0 ] || { echo "no actions found under ${repo_root}/.github/actions/" >&2; exit 1; }
fi

failures=0
fail() { echo "FAIL: $*" >&2; failures=$((failures + 1)); }
pass() { echo "ok:   $*"; }

check_action_dir() {
  local action_dir="$1"
  local action_yml="${action_dir}/action.yml"
  local name
  name="$(basename "$action_dir")"

  echo
  echo "── ${name} ──"

  if [ ! -f "$action_yml" ]; then
    fail "${name}: no action.yml"
    return
  fi

  # --- No third-party action references, and no relative ones either ----------
  # Permitted: the GitHub-authored actions/* org, allowed by the policy's
  # "created by GitHub" clause. `github/*` is deliberately NOT permitted here:
  # the same clause covers it, but it is GitHub's product org rather than the
  # runner action org, and nothing in these actions needs it.
  #
  # `uses: ./...` is rejected too, which looks wrong for a vendored action and is
  # not. A relative reference inside a composite action resolves against the
  # CALLER's workspace, not the action's own directory — so a `./` step here
  # would go looking inside the consuming repo's checkout and fail there, while
  # working perfectly in the repo that owns the copy. Files belonging to an
  # action are reached through ${{ github.action_path }}.
  local offending
  offending="$(grep -nE '^[[:space:]]*-?[[:space:]]*uses:' "$action_yml" \
    | grep -vE "uses:[[:space:]]*'?\"?actions/" || true)"
  if [ -n "$offending" ]; then
    fail "${name}: disallowed action reference(s):"
    printf '%s\n' "$offending" >&2
    echo "  Only actions/* is allowed. For files inside the action, use \${{ github.action_path }}." >&2
  else
    pass "${name}: every 'uses:' is an actions/* action; no relative references"
  fi

  # --- The removed curl|bash bootstrap has not crept back ---------------------
  # Comment lines are stripped first: action.yml and README.md quote the upstream
  # `curl | bash` line in prose to explain what was replaced, and that prose must
  # not trip the check.
  local scripts=() piped
  while IFS= read -r f; do scripts+=("$f"); done < <(find "$action_dir" -maxdepth 1 -name '*.sh' -type f | sort)
  piped="$(cat "$action_yml" "${scripts[@]}" 2>/dev/null \
    | grep -vE '^[[:space:]]*#' \
    | grep -nE '(curl|wget)[^|]*\|[[:space:]]*(bash|sh)\b' || true)"
  if [ -n "$piped" ]; then
    fail "${name}: a remote script is piped into a shell; install a pinned, checksummed asset instead"
    printf '%s\n' "$piped" >&2
  else
    pass "${name}: no remote script piped into a shell"
  fi

  # --- Shell scripts are valid, and clean ------------------------------------
  local s
  for s in "${scripts[@]}"; do
    if bash -n "$s"; then
      pass "${name}: $(basename "$s") parses"
    else
      fail "${name}: $(basename "$s") has a syntax error"
    fi
    if command -v shellcheck >/dev/null 2>&1; then
      if shellcheck "$s"; then
        pass "${name}: $(basename "$s") passes shellcheck"
      else
        fail "${name}: $(basename "$s") has shellcheck findings"
      fi
    fi
  done

  # --- Connector-specific -----------------------------------------------------
  # `return 0`, not a bare `return`: a bare one carries the failed test's status
  # out of the function, and under `set -e` that aborts the whole run on the
  # first action that simply is not the connector.
  if [ -f "${action_dir}/install-jbang.sh" ]; then
    check_connector "$name" "$action_yml"
  fi
  return 0
}

check_connector() {
  local name="$1" action_yml="$2"

  local jbang_version jbang_sha
  jbang_version="$(sed -n "s/^[[:space:]]*JBANG_VERSION:[[:space:]]*'\([^']*\)'.*/\1/p" "$action_yml" | head -1)"
  jbang_sha="$(sed -n "s/^[[:space:]]*JBANG_SHA256:[[:space:]]*'\([^']*\)'.*/\1/p" "$action_yml" | head -1)"
  if [ -z "$jbang_version" ] || [ -z "$jbang_sha" ]; then
    fail "${name}: the Install JBang step must pin both JBANG_VERSION and JBANG_SHA256 (found version='${jbang_version}' sha='${jbang_sha}')"
  elif [ "${#jbang_sha}" -ne 64 ]; then
    fail "${name}: JBANG_SHA256 is ${#jbang_sha} characters; a SHA-256 is 64"
  else
    pass "${name}: JBang pinned to ${jbang_version} with a 64-character checksum"
  fi

  # The connector version appears twice by necessity: `key:` has to be a literal
  # expression, and the jbang command line has to name the artifact.
  local run_version key_version
  run_version="$(sed -n 's/.*com\.streamx:streamx-github-connector:\([0-9][^ ]*\).*/\1/p' "$action_yml" | head -1)"
  key_version="$(sed -n 's/.*m2-streamx-connector-\([0-9][^[:space:]]*\).*/\1/p' "$action_yml" | head -1)"
  if [ -z "$run_version" ]; then
    fail "${name}: could not find the com.streamx:streamx-github-connector coordinate"
  elif [ "$run_version" != "$key_version" ]; then
    fail "${name}: connector version drift — the jbang command runs ${run_version} but the cache key says ${key_version:-<none>}"
  else
    pass "${name}: connector ${run_version} matches the cache key"
  fi

  # Extra inputs leak into JSON_INPUTS and become connector configuration.
  local expected_inputs actual_inputs
  expected_inputs="debug-enabled deleted-event-type event-data event-type external-resource-url include-patterns snapshot-artifactory-token source-provider streamx-ingestion-token streamx-ingestion-url subject workspace"
  actual_inputs="$(sed -n '/^inputs:/,/^runs:/p' "$action_yml" | sed -n 's/^  \([a-z0-9-]*\):.*/\1/p' | sort | tr '\n' ' ' | sed 's/ $//')"
  if [ "$actual_inputs" != "$expected_inputs" ]; then
    fail "${name}: input surface has diverged from upstream's"
    echo "  expected: ${expected_inputs}" >&2
    echo "  actual:   ${actual_inputs}" >&2
  else
    pass "${name}: all 12 upstream inputs present, none added"
  fi
}

for d in "${action_dirs[@]}"; do
  check_action_dir "$d"
done

echo
if [ "$failures" -gt 0 ]; then
  echo "${failures} check(s) failed." >&2
  exit 1
fi
echo "All checks passed."
