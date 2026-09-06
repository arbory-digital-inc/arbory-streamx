# Debugging the mesh

Written after an outage on 2026-09-06 where published pages silently stopped
being indexed for two and a half hours while **every workflow run stayed green,
every service reported healthy, and no component logged a single error**. The
diagnosis took hours; with the notes below it takes about three minutes. That gap
is the reason this file exists.

The through-line: in a message mesh, the dangerous failures are not the loud ones.
A crash gets a log line and a red build. A message written to a topic nobody
subscribes to gets neither.

---

## Three-minute triage

Someone says "I published a page and it isn't in search". Run these in order and
stop at the first one that fails.

### 1. Is the content actually published?

```bash
curl -s https://main--arbory-dev--arbory-digital-inc.aem.live/en/blog/SOME-PAGE | grep -ic 'YOUR-WORD'
```

StreamX indexes what the connector sends, and the connector downloads this URL.
If the word isn't here, nothing downstream is at fault.

### 2. Did the workflow send it?

Look for these two lines in the `publish-to-streamx` job:

```
##[notice]Sending CloudEvent: subject='en:/en/blog/SOME-PAGE', ...
##[notice]CloudEvent 'en:/en/blog/SOME-PAGE' was sent successfully.
```

**"Sent successfully" means the ingestion API returned a success code. It does not
mean the page was indexed, and it does not mean anything consumed the message.**
Treating that line as proof is the single easiest way to lose an afternoon.

If you need more than that, run the `StreamX debug probe` workflow in `arbory-dev`
with `debug-enabled`, which prints the request the connector actually makes.

### 3. When did indexing last work? — the most useful question available

```bash
curl -s --get --data-urlencode 'size=1000' \
  'https://so-arborydigital-arboryda-7cef6.eu-central-waw-edge.prod-ext.streamx.cloud/search/eds-pages/' \
| python3 -c "
import json,sys,collections
d=json.load(sys.stdin)
ts=[h['_source'].get('payload',{}).get('ingested','') for h in d['hits']['hits']]
print('docs:', d['hits']['total']['value'])
for k,v in sorted(collections.Counter(t[:16] for t in ts if t).items()):
    print(' ', k, '->', v)
"
```

Every index operation stamps `payload.ingested`, so this bucketing shows exactly
when the pipeline last did any work. During the outage it printed:

```
docs: 52
  2026-09-06T17:55 -> 52
```

Fifty-two documents written inside one 1.5-second window and nothing since —
which dated the breakage to the minute and pointed straight at the deploy that
had happened sixty seconds earlier. **Reach for this before anything else.**

### 4. If indexing has stopped: check the chain is connected

See [The chain](#the-chain) below. This is where the 2026-09-06 fault was.

---

## Two hostnames, and they are not interchangeable

| | Host | Role |
| --- | --- | --- |
| **Ingestion** | `...eu-west-par-processing.prod-ext.streamx.cloud` | where the connector POSTs CloudEvents (`rest-ingestion`) |
| **Delivery** | `...eu-central-waw-edge.prod-ext.streamx.cloud` | where readers query (`/search` → `opensearch-sink`) |

Different regions, different clusters, different jobs. Passing one where the
other is expected produces a confusing 404 rather than a useful error. The
authoritative mapping is the console's **Gateways** page.

Repository variables: `STREAMX_INGESTION_URL` and `STREAMX_DELIVERY_URL`.

## The URL path picks the search template — and they project different fields

`/search/pages/` and `/search/eds-pages/` are two different OpenSearch search
templates over the **same index**. They return different `_source` fields:

```
/search/pages/      → payload: [title]
/search/eds-pages/  → payload: [ingested, title]     ← use this one to debug
```

Only `eds-pages` projects `payload.ingested`, so only `eds-pages` can answer
"when was this last indexed". A freshness check pointed at `/search/pages/` will
silently degrade to an existence check. The templates are defined in
`scripts/opensearch/configuration/search-templates/` and deployed as
`service-init` migrations.

## Existence is not freshness

A document being in the index says nothing about whether *this* publish did
anything. Re-publishing an already-indexed page satisfies an existence check
instantly, even when ingestion has been dead for hours — that exact false pass
happened on 2026-09-06 and delayed the diagnosis.

To prove an update landed, either:

- compare `payload.ingested` before and after (what the `verify-indexed` action
  does with `mode: read` + `previous-ingested`), or
- query for a word that appears only in the new content.

---

## The chain

Every page follows one path, and **every hop needs both a producer and a
consumer**. Print the whole map from `mesh.yaml`:

```bash
python3 -c "
import re
s=open('mesh/mesh.yaml').read()
for m in re.finditer(r'^  ([a-z0-9-]+):\n(.*?)(?=^  [a-z0-9-]+:|\Z)', s, re.S|re.M):
    n,b=m.group(1),m.group(2)
    ins=re.findall(r'incoming:(.*?)(?=outgoing:|environment|volumesFrom|servicePorts|autoRef|environmentFrom|\Z)',b,re.S)
    outs=re.findall(r'outgoing:(.*?)(?=incoming:|environment|volumesFrom|servicePorts|autoRef|environmentFrom|\Z)',b,re.S)
    i=[x for q in ins for x in re.findall(r'ref:\s*(\S+)',q)]
    o=[x for q in outs for x in re.findall(r'ref:\s*(\S+)',q)]
    if i or o: print(f'{n:36} IN {i}  OUT {o}')
"
```

The healthy page path:

```
github source           OUT inbox.pages
indexable-resources-producer   IN inbox.pages          OUT relay.indexable-resources
indexable-resources-relay      IN relay.indexable-resources  OUT outbox.indexable-resources
opensearch-sink                IN outbox.indexable-resources
```

**Read the map for orphans.** A channel that appears only as an `OUT` is being
written to with nobody listening; a channel that appears only as an `IN` is being
read from with nobody writing. Either one silently drops every message. On
2026-09-06 both existed at once:

```
github ──► inbox.pages          ← OUT only: nothing consumed it
           relay.pages ──► producer   ← IN only: nothing produced it
```

A restructure had re-pointed the producer's input to `relay.pages` without adding
anything to feed it. Publishes went into `inbox.pages` and stopped there.

## The zero-backlog trap

**A channel with no subscriber reports a backlog of zero.** Backlog counts
unacknowledged messages *per subscription*; no subscription means nothing to
count. So the console's Channels page showed `0` across the board while the
pipeline was completely severed — the display was indistinguishable from perfect
health.

Corollaries worth remembering:

- All-zeros is **not** evidence of health. Confirm the chain is connected first.
- A *non-zero* backlog is not automatically today's problem either. The one
  non-zero number during this outage (`outbox.indexable-resources` = 27) had been
  stuck since 30 August and was unrelated. Check the graph's time axis before
  building a theory on it.

## Health endpoints

The ingestion service exposes Quarkus health, unauthenticated:

```bash
curl -s https://so-arborydigital-arboryda-7cef6.eu-west-par-processing.prod-ext.streamx.cloud/q/health
```

It lists the source channels it is proxying (`data-sx-proxy-inbox.pages` etc.).
Useful for confirming ingestion is alive — but note it says nothing about whether
anything downstream consumes those channels.

The delivery host does **not** expose `/q/health`, `_mapping`, `_cat/indices` or
any other OpenSearch admin API. Only the named search templates are reachable.
Requests to unknown paths log `Search template with searchTemplateId {0} could
not be found` in the sink — those lines are usually your own probing, not a fault.

## Config lives in more places than you expect

`streamx deploy` manages the `ServiceMesh` resource plus **Secrets** from
`mesh/secrets/` and **ConfigMaps** from `mesh/configs/`. A service reads its
configuration from a ConfigMap mounted by `volumesFrom`, so changing a file's
name or format in `mesh/configs/` changes what the service sees, even when
`mesh.yaml` looks untouched.

Pushing to `main` triggers a redeploy — the mesh sources its config from this
repo, and merges here restart services. That is convenient and occasionally
surprising: a merge during an incident will restart things mid-investigation.

`service-init` migrations under `mesh/configs/opensearch/service-init/` run at
**sink startup**, in version order, via Elasticsearch Evolution (history index
`es_evolution`, `validateOnMigrate=true`, `outOfOrder=false`). Consequences:

- A failing migration blocks every later one, so a fix must usually **replace**
  the failing file rather than be added after it.
- Applied migrations are checksummed. Editing one that already ran is its own
  failure mode.
- `format-search-templates.sh` regenerates **every** registered template and will
  rewrite already-applied migration files with whitespace differences. Revert
  anything it touches other than the file you meant to change.

---

## What misled us on 2026-09-06

Worth reading before trusting any single signal:

| Signal | Said | Actually |
| --- | --- | --- |
| Workflow runs | green | correct, and irrelevant — they only prove the API accepted the event |
| `CloudEvent ... sent successfully` | delivered | accepted by `rest-ingestion`; nothing had consumed it |
| Every service | healthy | true; nothing was failing, messages had nowhere to go |
| Channels page all zeros | healthy | no subscriber means no backlog to report |
| `outbox.indexable-resources` = 27 | today's backlog | stuck since 30 August, unrelated |
| An existence check on a re-published page | passed | the document was already there from before the break |
| Sink logs | silent | it was never handed anything to fail on |

The only signal that told the truth was `payload.ingested`. Start there.
