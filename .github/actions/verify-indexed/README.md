# StreamX index verification action

Polls a StreamX **delivery** endpoint until a document is — or is no longer — in
the search index, and fails the job if it never gets there.

Like the connector action next door, it references no third-party action (it has
no `uses:` at all), so it runs under an actions allow-list limited to
enterprise-owned, GitHub-authored or Marketplace-verified actions.

## Why

The connector logs `CloudEvent ... was sent successfully` and the job goes green.
That sentence means the ingestion API accepted the event. It does not mean the
document was indexed, and it does not mean a reader can find it. Everything after
ingestion — fetching the page, indexing it, replicating to the edge — is
asynchronous and invisible to the workflow that triggered it.

Which means **a pipeline that has silently stopped indexing looks exactly like a
working one from inside GitHub Actions**. This action is what makes the
difference visible, by asking the same endpoint a reader's browser asks.

## The two modes are not interchangeable

| Mode | Selected by | Answers |
| --- | --- | --- |
| **existence** | leaving `query` empty | *Is this document in the index at all?* Enumerates the index with the search template's `match_all` behaviour, paging until the id is found or the index is exhausted. Independent of content. |
| **content** | setting `query` | *Is this document findable by this term?* Asserts the id appears among the results for that query. |

The distinction is the whole point:

- **A re-publish of an already-indexed page passes the existence check
  instantly, while proving nothing about the new text.** Existence catches total
  pipeline breakage, not staleness. To prove an update actually landed, query for
  a term that only appears in the new content — that is what the freshness canary
  does with a unique marker.
- **For `expect: absent`, existence is the only sound mode.** A document can be
  missing from a query's results simply because it does not match, so "absent
  under a query" is not evidence of "removed from the index". The action warns if
  asked to do that.

### Freshness: the gap that existence cannot close

An existence check passes the instant it is asked for any page that has ever been
indexed. If ingestion silently stops — an expired token, a delivery URL left
pointing at a retired mesh, a page fetcher that started 404ing — every publish
still goes green against a document that was indexed months ago. **A check that
cannot fail is worse than no check, because it is trusted.**

The index already knows better. The default ingest pipeline stamps
`payload.ingested` on every index operation, and the mapping types it as a date.
So: read the stamp before publishing (`mode: read`), pass it back as
`previous-ingested`, and the check only passes once the index is showing a
*different* one. Comparing two readings taken from the same clock also sidesteps
any skew between the runner and the search cluster.

This requires the search template to project `payload.ingested` in its `_source`.
Until it does, the action says so in a warning and degrades to an existence
check rather than pretending. The other way to prove freshness needs no template
change: query for a word that appears only in the new text.

A capped scan is never treated as proof of absence: if the index is larger than
`max-scan`, the action fails and says so rather than reporting a clean bill of
health it did not earn.

## Usage

```yaml
- name: Confirm the page reached the search index
  uses: <your-org>/<your-streamx-repo>/.github/actions/verify-indexed@v1
  with:
    delivery-url: ${{ vars.STREAMX_DELIVERY_URL }}
    subject: ${{ steps.vars.outputs.streamx_subject }}
```

The mirror, after an unpublish:

```yaml
- name: Confirm the page left the search index
  uses: <your-org>/<your-streamx-repo>/.github/actions/verify-indexed@v1
  with:
    delivery-url: ${{ vars.STREAMX_DELIVERY_URL }}
    subject: ${{ steps.vars.outputs.streamx_subject }}
    expect: absent
```

`delivery-url` is the **delivery/edge** host, which is not the ingestion host —
they differ by region and role. Ingestion looks like
`https://<mesh>.<region>-processing.prod-ext.streamx.cloud`; delivery looks like
`https://<mesh>.<region>-edge.prod-ext.streamx.cloud`. Passing the ingestion URL
gets you a confusing 404 rather than a useful error, so keep it in a repository
variable and set it once.

## Outputs

`found`, `total-hits`, and `elapsed-seconds` — the last being the pipeline
latency from ingestion to queryable. It is worth glancing at: a number that
creeps up over weeks is the earliest warning you will get that the mesh is
struggling.

## Notes

- The document `_id` **is** the CloudEvent subject, which is what makes an exact
  assertion possible. Asserting that a query returns *something* would prove
  nothing about the page you just published.
- Every poll sends a cache-buster and no-cache headers. The endpoint advertises
  no caching today, but polling for a state change through anything that might
  cache is how a test ends up asserting against a stale answer.
- `jq` is used when present, with a text-extraction fallback for hardened
  runners that lack it. Both paths are exercised by this repository's CI.
- A 200 response is not automatically a *search* response. An HTML maintenance
  page, a WAF interstitial, a redirecting apex domain, or the ingestion URL used
  by mistake all parse as "zero hits" — which would **satisfy** an `absent`
  assertion. The action requires the body to be OpenSearch-shaped before it will
  interpret it at all.
- A failed request to the delivery host is reported differently from a missing
  document — a misconfigured URL or a TLS-inspecting proxy is not an ingestion
  failure, and sending someone to debug the wrong system wastes the outage.
