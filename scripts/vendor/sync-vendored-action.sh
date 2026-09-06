#!/usr/bin/env bash
#
# Copy the internalized StreamX connector action into a consuming repository,
# for the path-vendored consumption mode:
#
#     uses: ./.github/actions/connector-github
#
# This is the fallback mode. Referencing the action cross-repo
# (`uses: <org>/<streamx-repo>/.github/actions/connector-github@v1`) keeps one
# copy in one place and should be preferred; path-vendoring is for when the
# consuming repo cannot be granted read access to the action repo, or when a
# workflow must keep working with no cross-repo dependency at all.
#
# Path-vendoring buys independence and pays for it in copies. Copies drift, so
# every copy carries a manifest and `--check` proves it still matches source.
# Wire `--check` into the consuming repo's CI; a silently stale copy is worse
# than no copy, because it fails in production with a fixed bug.
#
# Usage:
#   sync-vendored-action.sh <target-repo-root> [--check] [action-name]
#
#   action-name defaults to connector-github. Pass verify-indexed to vendor the
#   index verifier instead; both are needed if the consuming repo cannot
#   reference this one cross-repo.
set -euo pipefail

source_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

usage() { echo "usage: $(basename "$0") <target-repo-root> [--check] [action-name]" >&2; exit 2; }

target_root="${1:-}"
mode="${2:-sync}"
action_name="${3:-connector-github}"
[ -n "$target_root" ] || usage
[ "$mode" = "sync" ] || [ "$mode" = "--check" ] || usage

source_dir="${source_root}/.github/actions/${action_name}"
rel_dir=".github/actions/${action_name}"
[ -f "${source_dir}/action.yml" ] || { echo "error: no action at ${rel_dir}" >&2; exit 1; }

# Everything the action is made of, plus the guard — a vendored copy without the
# guard has no way to notice it has broken the one property it exists to hold.
# The manifest is generated per target and is deliberately excluded from the
# comparison set, so it can record the hashes without changing what is hashed.
FILES=()
while IFS= read -r f; do FILES+=("$(basename "$f")"); done < <(
  find "$source_dir" -maxdepth 1 -type f \( -name '*.yml' -o -name '*.sh' -o -name '*.md' \) | sort
)
FILES+=(check-allowlist-safety.sh)
MANIFEST="VENDORED-FROM.txt"

if [ ! -d "$target_root" ]; then
  echo "error: target repo root does not exist: ${target_root}" >&2
  exit 1
fi
if [ ! -d "${target_root}/.git" ]; then
  echo "error: ${target_root} is not a git repository root." >&2
  echo "       Point this at the top of the consuming repo, not at its .github directory." >&2
  exit 1
fi

target_dir="${target_root}/${rel_dir}"

hash_of() {
  sha256sum "$1" | cut -d' ' -f1
}

# --- check mode ---------------------------------------------------------------
if [ "$mode" = "--check" ]; then
  if [ ! -d "$target_dir" ]; then
    echo "DRIFT: ${target_root} has no vendored copy at ${rel_dir}" >&2
    exit 1
  fi
  drift=0
  for f in "${FILES[@]}"; do
    src="${source_dir}/${f}"
    [ "$f" = "check-allowlist-safety.sh" ] && src="${source_root}/scripts/vendor/${f}"
    if [ ! -f "${target_dir}/${f}" ]; then
      echo "DRIFT: missing ${rel_dir}/${f}" >&2
      drift=1
      continue
    fi
    if [ "$(hash_of "$src")" != "$(hash_of "${target_dir}/${f}")" ]; then
      echo "DRIFT: ${rel_dir}/${f} differs from source" >&2
      diff -u "${target_dir}/${f}" "$src" | sed 's/^/    /' >&2 || true
      drift=1
    fi
  done
  if [ "$drift" -ne 0 ]; then
    echo >&2
    echo "The vendored copy is out of date. Re-run without --check to update it:" >&2
    echo "    ${BASH_SOURCE[0]} ${target_root}" >&2
    exit 1
  fi
  echo "The vendored copy in ${target_root} matches source."
  exit 0
fi

# --- sync mode ----------------------------------------------------------------
# Refuse to overwrite local edits unless they are already committed somewhere:
# a hand-patched vendored copy is a real (if unwise) situation, and silently
# discarding someone's fix is worse than stopping and saying so.
if [ -d "$target_dir" ]; then
  for f in "${FILES[@]}"; do
    [ -f "${target_dir}/${f}" ] || continue
    src="${source_dir}/${f}"
    [ "$f" = "check-allowlist-safety.sh" ] && src="${source_root}/scripts/vendor/${f}"
    if [ "$(hash_of "$src")" != "$(hash_of "${target_dir}/${f}")" ]; then
      if ! git -C "$target_root" ls-files --error-unmatch -- "${rel_dir}/${f}" >/dev/null 2>&1; then
        echo "error: ${rel_dir}/${f} differs from source and is not tracked by git." >&2
        echo "       An untracked local copy cannot be recovered once overwritten." >&2
        exit 1
      fi
      if ! git -C "$target_root" diff --quiet -- "${rel_dir}/${f}" 2>/dev/null; then
        echo "error: ${rel_dir}/${f} has uncommitted local changes in the target repo." >&2
        echo "       Commit or discard them first — this script would overwrite them." >&2
        exit 1
      fi
    fi
  done
fi

source_commit="$(git -C "$source_root" rev-parse HEAD 2>/dev/null || echo unknown)"
source_remote="$(git -C "$source_root" remote get-url origin 2>/dev/null || echo unknown)"
source_dirty=""
git -C "$source_root" diff --quiet -- "$rel_dir" 2>/dev/null || source_dirty=" (UNCOMMITTED CHANGES PRESENT)"

mkdir -p "$target_dir"
for f in "${FILES[@]}"; do
  if [ "$f" = "check-allowlist-safety.sh" ]; then
    install -m 0644 "${source_root}/scripts/vendor/${f}" "${target_dir}/${f}"
  else
    install -m 0644 "${source_dir}/${f}" "${target_dir}/${f}"
  fi
done
chmod 0755 "${target_dir}/install-jbang.sh" "${target_dir}/check-allowlist-safety.sh"

{
  echo "This directory is a vendored copy. Do not edit it here."
  echo
  echo "Source repo:   ${source_remote}"
  echo "Source path:   ${rel_dir}"
  echo "Source commit: ${source_commit}${source_dirty}"
  echo "Synced by:     scripts/vendor/sync-vendored-action.sh"
  echo "Synced at:     $(date -u +%Y-%m-%dT%H:%M:%SZ)"
  echo
  echo "Edit the source, then re-run the sync script. To detect drift in CI:"
  echo "    sync-vendored-action.sh <this-repo-root> --check"
  echo
  echo "sha256:"
  for f in "${FILES[@]}"; do
    echo "  $(hash_of "${target_dir}/${f}")  ${f}"
  done
} > "${target_dir}/${MANIFEST}"

echo "Vendored into ${target_dir}:"
for f in "${FILES[@]}" "$MANIFEST"; do
  echo "  ${rel_dir}/${f}"
done
echo
echo "Reference it from a workflow as:  uses: ./${rel_dir}"
echo "Remember that a local action needs actions/checkout to have run first."
