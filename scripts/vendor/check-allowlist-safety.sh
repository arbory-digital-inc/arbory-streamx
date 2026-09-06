#!/usr/bin/env bash
#
# Assert that a vendored action stays usable under a GitHub Actions allow-list
# restricted to "enterprise-owned, GitHub-authored, or Marketplace-verified".
#
# The whole value of vendoring the StreamX connector action is one invariant:
# nothing in it references a third-party action. That invariant is invisible —
# a single well-meaning `uses: some/handy-action@v2` reintroduces the original
# failure, and it will not fail in the repo that holds the action. It will fail
# in the consuming repo, at publish time, in someone else's org.
#
# So it is checked mechanically. Run it in CI in every repo that hosts a copy.
#
# Usage: check-allowlist-safety.sh [action-dir]
#        defaults to .github/actions/connector-github relative to the repo root
set -euo pipefail

action_dir="${1:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)/.github/actions/connector-github}"
action_yml="${action_dir}/action.yml"
installer="${action_dir}/install-jbang.sh"

failures=0
fail() { echo "FAIL: $*" >&2; failures=$((failures + 1)); }
pass() { echo "ok:   $*"; }

if [ ! -f "$action_yml" ]; then
  echo "FAIL: no action.yml at ${action_yml}" >&2
  exit 1
fi

# --- 1. No third-party action references -------------------------------------
# Permitted: a local path (./...) and the GitHub-authored actions/* org.
# `github/*` is deliberately NOT permitted: it is GitHub-the-company's product
# org, not the runner's action org, and an allow-list may treat it differently.
offending="$(grep -nE '^[[:space:]]*-?[[:space:]]*uses:' "$action_yml" \
  | grep -vE 'uses:[[:space:]]*'"'"'?"?(\./|actions/)' || true)"
if [ -n "$offending" ]; then
  fail "third-party action reference(s) in $(basename "$action_yml"):"
  printf '%s\n' "$offending" >&2
else
  pass "every 'uses:' is a local path or an actions/* action"
fi

# --- 2. The removed curl|bash bootstrap has not crept back --------------------
# Only executable files are scanned, and comment lines are stripped first: both
# action.yml and README.md quote the upstream `curl | bash` line in prose to
# explain what was replaced, and that prose must not trip the check.
piped="$(cat "$action_yml" "${installer:-/dev/null}" 2>/dev/null \
  | grep -vE '^[[:space:]]*#' \
  | grep -nE '(curl|wget)[^|]*\|[[:space:]]*(bash|sh)\b' || true)"
if [ -n "$piped" ]; then
  fail "a remote script is being piped into a shell; install a pinned, checksummed asset instead"
  printf '%s\n' "$piped" >&2
else
  pass "no remote script piped into a shell"
fi

# --- 3. JBang pins are both present ------------------------------------------
jbang_version="$(grep -oP "^\s+JBANG_VERSION:\s*'\K[^']+" "$action_yml" || true)"
jbang_sha="$(grep -oP "^\s+JBANG_SHA256:\s*'\K[^']+" "$action_yml" || true)"
if [ -z "$jbang_version" ] || [ -z "$jbang_sha" ]; then
  fail "the Install JBang step must pin both JBANG_VERSION and JBANG_SHA256 (found version='${jbang_version}' sha='${jbang_sha}')"
elif [ "${#jbang_sha}" -ne 64 ]; then
  fail "JBANG_SHA256 is ${#jbang_sha} characters; a SHA-256 is 64"
else
  pass "JBang pinned to ${jbang_version} with a 64-character checksum"
fi

# --- 4. The connector version agrees with the cache key ----------------------
# It appears twice by necessity: `key:` has to be a literal expression, and the
# jbang command line has to name the artifact. Twice means it can drift.
run_version="$(grep -oP 'com\.streamx:streamx-github-connector:\K[0-9][^ ]*' "$action_yml" | head -1 || true)"
key_version="$(grep -oP 'm2-streamx-connector-\K[0-9][^\s]*' "$action_yml" | head -1 || true)"
if [ -z "$run_version" ]; then
  fail "could not find the com.streamx:streamx-github-connector coordinate"
elif [ "$run_version" != "$key_version" ]; then
  fail "connector version drift: the jbang command runs ${run_version} but the cache key says ${key_version:-<none>}"
else
  pass "connector ${run_version} matches the cache key"
fi

# --- 5. The installer is valid bash ------------------------------------------
if [ -f "$installer" ]; then
  if bash -n "$installer"; then
    pass "install-jbang.sh parses"
  else
    fail "install-jbang.sh has a syntax error"
  fi
  if command -v shellcheck >/dev/null 2>&1; then
    if shellcheck "$installer"; then
      pass "install-jbang.sh passes shellcheck"
    else
      fail "install-jbang.sh has shellcheck findings"
    fi
  else
    echo "note: shellcheck not installed; skipped"
  fi
else
  fail "no install-jbang.sh next to action.yml"
fi

# --- 6. Input surface still matches upstream's ---------------------------------
# Extra inputs leak into JSON_INPUTS and become connector configuration.
expected_inputs="debug-enabled deleted-event-type event-data event-type external-resource-url include-patterns snapshot-artifactory-token source-provider streamx-ingestion-token streamx-ingestion-url subject workspace"
actual_inputs="$(sed -n '/^inputs:/,/^runs:/p' "$action_yml" | grep -oP "^  \K[a-z0-9-]+(?=:)" | sort | tr '\n' ' ' | sed 's/ $//')"
if [ "$actual_inputs" != "$expected_inputs" ]; then
  fail "input surface has diverged from upstream's"
  echo "  expected: ${expected_inputs}" >&2
  echo "  actual:   ${actual_inputs}" >&2
else
  pass "all 12 upstream inputs present, none added"
fi

echo
if [ "$failures" -gt 0 ]; then
  echo "${failures} check(s) failed." >&2
  exit 1
fi
echo "All checks passed."
