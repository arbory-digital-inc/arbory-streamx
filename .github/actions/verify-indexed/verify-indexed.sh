#!/usr/bin/env bash
#
# Poll a StreamX delivery endpoint until a document is (or is no longer) in the
# search index.
#
# WHY THIS EXISTS
# ---------------
# The connector reports "CloudEvent ... was sent successfully" and the job goes
# green. That sentence means the ingestion API accepted the event. It does not
# mean the document was indexed, and it does not mean a reader can find it —
# everything after ingestion is asynchronous and invisible to the workflow that
# triggered it. A pipeline that has silently stopped indexing looks exactly like
# a working one from inside GitHub Actions.
#
# So the assertion is made from outside, against the same endpoint a reader's
# browser hits, and on the document id rather than on "did the query return
# anything" — StreamX uses the CloudEvent subject as the document `_id`, so the
# check can be exact. A query for "streamx" returning *some* page proves nothing
# about the page that was just published.
#
# TWO MODES, AND THE DIFFERENCE MATTERS
# -------------------------------------
#   existence (SX_QUERY empty)
#     Enumerates the index with the template's match_all behaviour, paging until
#     the id is found or the index is exhausted. Answers "is this document
#     indexed at all", independently of whether its content matches anything.
#
#   content (SX_QUERY set)
#     Asserts the id appears among the results FOR THAT QUERY. Answers "is this
#     document findable by this term", which is the only way to prove a content
#     UPDATE landed: a re-publish of an already-indexed page passes the existence
#     check instantly while proving nothing about the new text.
#
# Use existence for the automatic per-publish check, and content with a unique
# marker for a true end-to-end freshness canary.
#
# For SX_EXPECT=absent, existence mode is the only sound choice: a document can
# be missing from a query's results simply because it does not match, so
# "absent under a query" is not evidence of "removed from the index". The script
# warns if asked to do that.
#
# Required environment:
#   SX_DELIVERY_URL   base URL, e.g. https://<mesh>.<region>.prod-ext.streamx.cloud
#   SX_SUBJECT        the CloudEvent subject == the document _id, e.g. en:/en/blog/x
#
# Optional environment:
#   SX_QUERY          search term; empty selects existence mode (see above)
#   SX_SEARCH_PATH    default /search/pages/
#   SX_EXPECT         present (default) | absent
#   SX_NAMESPACE      namespace filter passed to the search template
#   SX_TIMEOUT        seconds to keep polling, default 300
#   SX_INTERVAL       seconds between polls, default 10
#   SX_SIZE           page size per request, default 200
#   SX_MAX_SCAN       most documents existence mode will page through, default 2000
set -euo pipefail

delivery_url="${SX_DELIVERY_URL:-}"
subject="${SX_SUBJECT:-}"
query="${SX_QUERY:-}"
search_path="${SX_SEARCH_PATH:-/search/pages/}"
expect="${SX_EXPECT:-present}"
namespace="${SX_NAMESPACE:-}"
timeout_s="${SX_TIMEOUT:-300}"
interval_s="${SX_INTERVAL:-10}"
size="${SX_SIZE:-200}"
max_scan="${SX_MAX_SCAN:-2000}"
previous_ingested="${SX_PREVIOUS_INGESTED:-}"
op="${SX_MODE:-verify}"

die() { echo "::error::$*"; exit 1; }

[ -n "$delivery_url" ] || die "verify-indexed needs SX_DELIVERY_URL — the StreamX DELIVERY/edge base URL, which is not the ingestion URL. If this is unset, the repository variable that feeds it has not been configured yet."
[ -n "$subject" ]      || die "verify-indexed needs SX_SUBJECT (the CloudEvent subject, which is the document _id)."
case "$expect" in
  present|absent) ;;
  *) die "SX_EXPECT must be 'present' or 'absent', got '${expect}'." ;;
esac
case "$op" in
  verify|read) ;;
  *) die "SX_MODE must be 'verify' or 'read', got '${op}'." ;;
esac

if [ -n "$query" ]; then
  mode=content
else
  mode=existence
fi

if [ "$expect" = absent ] && [ "$mode" = content ]; then
  echo "::warning::Asserting 'absent' with a query is weak evidence: a document missing from a"
  echo "::warning::query's results may simply not match that query. Leave the query empty to check"
  echo "::warning::the index itself."
fi

# Trim one trailing slash from the base and one leading slash from the path so
# the two always join with exactly one.
endpoint="${delivery_url%/}/${search_path#/}"

emit() { [ -n "${GITHUB_OUTPUT:-}" ] && echo "$1" >> "$GITHUB_OUTPUT"; return 0; }

# jq is present on GitHub-hosted runners and reads the shape exactly. The text
# fallback exists because a hardened self-hosted runner may not have it, and a
# verification step that cannot run is one that gets deleted. Both paths are
# exercised by this repository's own CI.
if command -v jq >/dev/null 2>&1; then
  parser=jq
else
  parser=text
fi

# A 200 response is not automatically a search response. curl follows redirects
# and only rejects >=400, so an HTML body — a WAF interstitial, a load-balancer
# maintenance page, an apex domain that redirects to marketing, or simply the
# EDS host pasted in place of the delivery host — arrives here looking fine. It
# then parses as zero hits, which SATISFIES an `absent` assertion. The unpublish
# check would pass against a host that has no search index at all.
looks_like_search_response() {
  if [ "$parser" = jq ]; then
    jq -e 'has("hits") and (.hits | has("total"))' "$1" >/dev/null 2>&1
  else
    grep -q '"total":[[:space:]]*{[[:space:]]*"value":[[:space:]]*[0-9]' "$1"
  fi
}

ids_from() {
  if [ "$parser" = jq ]; then
    jq -r '.hits.hits[]?._id // empty' "$1"
  else
    # On zero hits the response carries no inner "hits" array at all, so this
    # simply produces nothing — which is the correct answer.
    grep -oE '"_id":"[^"]*"' "$1" | sed 's/^"_id":"//; s/"$//'
  fi
}

# The index's own freshness stamp. The default ingest pipeline writes
# payload.ingested on EVERY index operation, so a changed value is proof that
# this document was really re-indexed — the one signal that separates "the
# document exists" from "this publish did something". It is only visible if the
# search template projects it in _source; when it does not, this returns nothing
# and the caller degrades to an existence check and says so.
ingested_from() {
  if [ "$parser" = jq ]; then
    jq -r --arg s "$subject" '.hits.hits[]? | select(._id == $s) | ._source.payload.ingested // empty' "$1" | head -1
  else
    tr ',' '\n' < "$1" | grep -oE '"ingested":"[^"]*"' | sed 's/^"ingested":"//; s/"$//' | head -1
  fi
}

total_from() {
  if [ "$parser" = jq ]; then
    jq -r '.hits.total.value // 0' "$1"
  else
    grep -oE '"total":\{"value":[0-9]+' "$1" | head -1 | grep -oE '[0-9]+$' || echo 0
  fi
}

work_dir="$(mktemp -d)"
trap 'rm -rf "$work_dir"' EXIT
response="${work_dir}/response.json"

# Fetch one page of results. Returns non-zero if the request itself failed.
fetch_page() {
  local from="$1" stamp="$2"
  local args=(--fail --silent --show-error --location
              --connect-timeout 15 --max-time 60
              -H 'Cache-Control: no-cache' -H 'Pragma: no-cache'
              --get
              --data-urlencode "size=${size}"
              --data-urlencode "from=${from}"
              --data-urlencode "_cb=${stamp}")
  [ -n "$query" ]     && args+=(--data-urlencode "query=${query}")
  [ -n "$namespace" ] && args+=(--data-urlencode "namespace=${namespace}")
  curl "${args[@]}" --output "$response" "$endpoint"
}

# One complete look at the index. Sets `hit`, `last_total` and `scanned`.
# Returns 0 if every request succeeded, 1 if any failed.
probe() {
  local stamp="$1"
  local from=0
  hit=0
  scanned=0
  last_total="unknown"

  while :; do
    fetch_page "$from" "${stamp}-${from}" || return 1
    if ! looks_like_search_response "$response"; then
      bad_response=1
      return 1
    fi
    last_total="$(total_from "$response")"
    ingested="$(ingested_from "$response")"

    if ids_from "$response" | grep -Fxq -- "$subject"; then
      hit=1
      return 0
    fi

    local page_count
    page_count="$(ids_from "$response" | sort -u | grep -c . || true)"
    scanned=$((scanned + page_count))

    # Content mode looks only at the query's own result set; paging past it would
    # be asserting something the caller did not ask about.
    [ "$mode" = content ] && return 0
    [ "$page_count" -eq 0 ] && return 0
    [ "$scanned" -ge "$last_total" ] 2>/dev/null && return 0
    if [ "$scanned" -ge "$max_scan" ]; then
      scan_capped=1
      return 0
    fi
    from=$((from + size))
  done
}

echo "::group::Verify '${subject}' is ${expect} in the StreamX index"
echo "endpoint : ${endpoint}"
echo "mode     : ${mode}$([ "$mode" = content ] && echo " (query: ${query})" || echo " (match_all — content-independent)")"
[ -n "$namespace" ] && echo "namespace: ${namespace}"
echo "expect   : ${expect}"
echo "timeout  : ${timeout_s}s, polling every ${interval_s}s"
[ "$parser" = text ] && echo "note     : jq not found; using text extraction of the search response"

started_at="$(date +%s)"
attempt=0
scan_capped=0
bad_response=0
hit=0
scanned=0
last_total="unknown"
ingested=""
warned_no_ingested=0

# `read` reports the current state and never fails the job. It exists so a
# workflow can record a document's freshness stamp BEFORE publishing and hand it
# back afterwards, which is what makes the freshness check immune to clock skew
# between the runner and the search cluster: it compares two readings from the
# same clock instead of trusting either one.
if [ "$op" = read ]; then
  bad_response=0
  http_ok=1
  probe "$(date +%s)-read" || http_ok=0
  if [ "$http_ok" -eq 1 ]; then
    echo "read: ${subject} is $([ "$hit" -eq 1 ] && echo present || echo absent)${ingested:+, ingested=${ingested}}"
  else
    echo "::warning::Could not read the current state of ${subject}; continuing without a baseline."
  fi
  echo "::endgroup::"
  emit "found=$([ "$hit" -eq 1 ] && echo true || echo false)"
  emit "ingested=${ingested}"
  emit "total-hits=${last_total}"
  emit "elapsed-seconds=0"
  exit 0
fi

while :; do
  attempt=$((attempt + 1))
  now="$(date +%s)"
  elapsed=$((now - started_at))

  http_ok=1
  bad_response=0
  probe "${now}-${attempt}" || http_ok=0

  if [ "$http_ok" -eq 1 ]; then
    # A document that was already indexed satisfies a presence check the instant
    # it is asked, which is why presence alone cannot tell a working pipeline
    # from one that silently stopped delivering. When the caller supplied the
    # value this document carried BEFORE the publish, require the index to be
    # showing a different one now.
    fresh=1
    if [ "$expect" = present ] && [ "$hit" -eq 1 ] && [ -n "$previous_ingested" ]; then
      if [ -z "$ingested" ]; then
        if [ "$warned_no_ingested" -eq 0 ]; then
          echo "::warning::The search template does not project payload.ingested, so freshness cannot be"
          echo "::warning::checked and this is an existence check only — it will pass for any page that was"
          echo "::warning::ever indexed, whether or not this publish changed anything. Add \"payload.ingested\""
          echo "::warning::to the template's _source projection to close that gap."
          warned_no_ingested=1
        fi
      elif [ "$ingested" = "$previous_ingested" ]; then
        fresh=0
      fi
    fi

    if { [ "$expect" = present ] && [ "$hit" -eq 1 ] && [ "$fresh" -eq 1 ]; } ||
       { [ "$expect" = absent ]  && [ "$hit" -eq 0 ] && [ "$scan_capped" -eq 0 ]; }; then
      echo "attempt ${attempt} (${elapsed}s): ${subject} is ${expect} — as expected."
      echo "::endgroup::"
      if [ -n "$previous_ingested" ] && [ -n "$ingested" ]; then
        echo "Verified in ${elapsed}s after ${attempt} poll(s): re-indexed at ${ingested} (was ${previous_ingested})."
      else
        echo "Verified in ${elapsed}s after ${attempt} poll(s). Index reported ${last_total} document(s) for this ${mode} check."
      fi
      emit "found=$([ "$hit" -eq 1 ] && echo true || echo false)"
      emit "elapsed-seconds=${elapsed}"
      emit "total-hits=${last_total}"
      emit "ingested=${ingested}"
      exit 0
    fi
    if [ "${fresh:-1}" -eq 0 ]; then
      echo "attempt ${attempt} (${elapsed}s): present, but still carrying the pre-publish stamp ${previous_ingested} — not re-indexed yet."
    else
      echo "attempt ${attempt} (${elapsed}s): not yet — ${subject} $([ "$hit" -eq 1 ] && echo present || echo absent), index reported ${last_total} document(s)."
    fi
  else
    echo "attempt ${attempt} (${elapsed}s): the request to the delivery endpoint failed; will retry."
  fi

  # Checked after polling so a timeout of 0 still performs one attempt.
  [ "$elapsed" -ge "$timeout_s" ] && break
  sleep "$interval_s"
done

echo "::endgroup::"
emit "found=$([ "$hit" -eq 1 ] && echo true || echo false)"
emit "elapsed-seconds=${elapsed}"
emit "total-hits=${last_total}"
emit "ingested=${ingested}"

if [ "$bad_response" -eq 1 ]; then
  echo "::error::The delivery endpoint returned a response that is not a search result."
  echo "::error::endpoint: ${endpoint}"
  echo "::error::That is a configuration problem, not an ingestion one — this is what happens when"
  echo "::error::the INGESTION url, an EDS host, or a redirecting apex domain is used as the"
  echo "::error::delivery url. Nothing about the index has been proven either way."
  exit 1
fi

if [ "${fresh:-1}" -eq 0 ]; then
  echo "::error::'${subject}' is in the index but was never re-indexed: it still carries the"
  echo "::error::stamp it had before this publish (${previous_ingested})."
  echo "::error::The ingestion API accepted the event and nothing acted on it — look at the mesh,"
  echo "::error::not at this workflow."
  exit 1
fi

echo "::error::Timed out after ${timeout_s}s: '${subject}' is still not ${expect} in the StreamX index."
echo "::error::endpoint: ${endpoint} (${mode} check)"
if [ "$http_ok" -ne 1 ]; then
  echo "::error::The last request to the delivery endpoint did not succeed at all. That is a"
  echo "::error::configuration or connectivity problem, not an ingestion one — check the delivery"
  echo "::error::URL, and on a self-hosted runner behind a TLS-inspecting proxy check the CA bundle."
elif [ "$scan_capped" -eq 1 ]; then
  echo "::error::Stopped after scanning ${max_scan} documents of ${last_total}, so this is NOT"
  echo "::error::evidence the document is missing. Narrow the check with a namespace, or raise"
  echo "::error::SX_MAX_SCAN."
elif [ "$mode" = content ]; then
  echo "::error::The query '${query}' matched ${last_total} document(s), and '${subject}' was not"
  echo "::error::among them. Note this cannot distinguish 'not indexed' from 'indexed but does not"
  echo "::error::match this query' — re-run without a query to check the index itself."
else
  echo "::error::Scanned ${scanned} of ${last_total} indexed document(s) and did not find it."
fi
exit 1
