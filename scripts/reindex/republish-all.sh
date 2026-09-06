#!/usr/bin/env bash
#
# Re-publish every page of an AEM Edge Delivery site, to rebuild a StreamX index
# from scratch.
#
# WHY IT GOES THROUGH THE PUBLISH PATH
# ------------------------------------
# The obvious shortcut is to read the sitemap and send CloudEvents directly. That
# requires re-deriving the CloudEvent subject from a URL, and the subject IS the
# document id — derive it differently by one character and you do not rebuild the
# index, you fill it with a second, parallel set of documents that nothing will
# ever update or remove.
#
# The publish workflow already derives subjects, from the `.md` path AEM sends in
# its dispatch, and that derivation is the one in production. So this script does
# not reimplement it. It asks AEM to publish the pages, AEM fires the same
# `resource-published` dispatch it always fires, and the existing workflow does
# the rest. Slower, and correct by construction.
#
# The content is already live, so re-publishing is an upsert: readers see no
# change.
#
# IT PUBLISHES ONE PATH AT A TIME, AND THAT IS NOT AN OVERSIGHT
# ------------------------------------------------------------
# AEM's admin API has a bulk form -- POST /live/{org}/{site}/{ref}/* with a paths
# array -- which is far faster and completely useless here. Measured 2026-09-06:
# bulk jobs complete and report success ("processed: 1, success: 1"), the pages
# really are published, and NO resource-published dispatch is emitted for any of
# them. Only the single-path form fires the dispatch this pipeline is built on.
#
# So a bulk rebuild looks like it worked, takes a fraction of the time, and
# indexes nothing. One request per page it is.
#
# Usage:
#   republish-all.sh --org O --site S --ref R [options]
#
#   --token-file F   file holding the AEM admin bearer token (default: ~/today-da-token.txt)
#   --sitemap URL    override the sitemap URL
#   --filter REGEX   only paths matching this
#   --batch N        publish this many, then pause (default 50)
#   --delay S        seconds to pause between batches (default 10)
#   --dry-run        list what would be published and stop
set -euo pipefail

org=""; site=""; ref=""
token_file="${HOME}/today-da-token.txt"
sitemap_url=""
filter=""
batch=50
delay=10
dry_run=0

while [ $# -gt 0 ]; do
  case "$1" in
    --org) org="$2"; shift 2 ;;
    --site) site="$2"; shift 2 ;;
    --ref) ref="$2"; shift 2 ;;
    --token-file) token_file="$2"; shift 2 ;;
    --sitemap) sitemap_url="$2"; shift 2 ;;
    --filter) filter="$2"; shift 2 ;;
    --batch) batch="$2"; shift 2 ;;
    --delay) delay="$2"; shift 2 ;;
    --dry-run) dry_run=1; shift ;;
    *) echo "unknown option: $1" >&2; exit 2 ;;
  esac
done

[ -n "$org" ] && [ -n "$site" ] && [ -n "$ref" ] || {
  echo "usage: $(basename "$0") --org O --site S --ref R [--dry-run]" >&2; exit 2; }

: "${sitemap_url:=https://${ref}--${site}--${org}.aem.live/sitemap.xml}"

work="$(mktemp -d)"; trap 'rm -rf "$work"' EXIT

echo "Reading ${sitemap_url}"
curl --fail --silent --show-error --location --max-time 60 -o "${work}/sitemap.xml" "$sitemap_url"

# Nav and footer are page-shaped but are not pages; the publish workflow already
# refuses to index them, so publishing them here would only make it do that work
# for nothing. Fragments are excluded for the same reason.
python3 - "$work/sitemap.xml" "$filter" > "${work}/paths.txt" <<'PY'
import re, sys
xml = open(sys.argv[1], encoding='utf-8', errors='replace').read()
flt = sys.argv[2]
paths = []
for loc in re.findall(r'<loc>\s*([^<]+?)\s*</loc>', xml):
    p = re.sub(r'^https?://[^/]+', '', loc)
    if not p.startswith('/'):
        continue
    if re.search(r'(/nav|/footer)$', p) or '/fragments/' in p:
        continue
    if flt and not re.search(flt, p):
        continue
    paths.append(p)
seen, out = set(), []
for p in paths:
    if p not in seen:
        seen.add(p); out.append(p)
print('\n'.join(out))
PY

count="$(grep -c . "${work}/paths.txt" || true)"
echo "${count} page(s) to publish (nav/footer/fragments excluded)"

if [ "$dry_run" -eq 1 ]; then
  cat "${work}/paths.txt"
  echo
  echo "(dry run — nothing published)"
  exit 0
fi

[ -f "$token_file" ] || { echo "error: no token file at ${token_file}" >&2; exit 1; }
token="$(tr -d '\n\r' < "$token_file")"
[ -n "$token" ] || { echo "error: token file ${token_file} is empty" >&2; exit 1; }

base="https://admin.hlx.page/live/${org}/${site}/${ref}"
total=0; failed=0; n=0
count="$(grep -c . "${work}/paths.txt" || true)"

while IFS= read -r path; do
  [ -n "$path" ] || continue
  n=$((n + 1))
  code="$(curl --silent --show-error --location --max-time 120 \
      -o /dev/null -w '%{http_code}' \
      -X POST "${base}${path}" \
      -H "Authorization: Bearer ${token}" || echo 000)"

  case "$code" in
    200|202|204) total=$((total + 1)) ;;
    *) failed=$((failed + 1)); echo "  ${path}: FAILED (HTTP ${code})" >&2 ;;
  esac

  if [ $((n % batch)) -eq 0 ] && [ "$n" -lt "$count" ]; then
    echo "  ${n}/${count} published (${failed} failed); pausing ${delay}s"
    sleep "$delay"
  fi
done < "${work}/paths.txt"

echo
echo "Published ${total} page(s); ${failed} failed."
echo "Each publish fires a resource-published dispatch, so watch the workflow runs"
echo "and then confirm the index actually grew — an accepted publish is not an"
echo "indexed page, which is the whole reason this rebuild is happening."
