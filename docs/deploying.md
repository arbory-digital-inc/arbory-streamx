# Deploying the mesh

What a merge here actually does, what it costs readers, and the ways a deploy
goes wrong that the console does not report. Most of this was learned the hard
way on a two-mesh production setup built from this repository (a dev mesh fed
from `develop`, a prod mesh from `main`) between September and November 2026,
and is written down here so the next mesh starts with it.

Companion to [debugging-the-mesh.md](debugging-the-mesh.md), which covers "a
page was published and is not in search".

---

## What a merge does

**Merging to the sourced branch redeploys the mesh, automatically.** StreamX
pulls this repository and applies `mesh/`. There is no deploy button and no
approval step, so the PR is the last gate.

`streamx deploy` manages the `ServiceMesh` resource plus Secrets from
`mesh/secrets/` and ConfigMaps from `mesh/configs/`. Only services whose pod
spec changed roll:

- A change to a service's definition in `mesh.yaml` rolls that service.
- Any change under `mesh/configs/opensearch/` rolls `opensearch-sink`: a new
  migration, and also any other file added to that directory (a checksum
  manifest, a README), because the directory is mounted whole.
- A change to a mounted ConfigMap is **not part of the pod spec**, and nothing
  guarantees it restarts the service that reads it. See [the restart
  lever](#the-restart-lever).

Before merging during an incident, work out which mesh and which services you
are about to bounce. A merge mid-investigation restarts the thing you are
looking at.

## Hostnames are cluster names

A StreamX URL is:

```
https://<project-id>.<cluster>.prod-ext.streamx.cloud
```

so the cluster names in `mesh/cloud-config.yaml` **are** the hostnames. Moving a
cluster renames its host. Every consumer of the old name breaks silently:

| Consumer | Where it lives |
| --- | --- |
| Ingestion URL (publishes) | the publishing repo's `STREAMX_INGESTION_URL` variable |
| Delivery URL (read-back checks, smoke tests) | `STREAMX_DELIVERY_URL` |
| `/search/*` and feed routing for readers | the CDN origin (AEM `config/cdn.yaml`) |

**You cannot probe your way to the right host.** StreamX's public DNS is a
per-region wildcard: a nonexistent project id still resolves, and a wrong
cluster in a real region still answers (with a 404). A region StreamX does not
run returns NXDOMAIN, so DNS can tell you a region exists and nothing more. The
console's **Gateways** page is the only authority for a project's hostnames.

### 404 and 503 mean different things

- **404 on every path**: there is no gateway for this project on this cluster.
  No mesh definition on the sourced branch, the wrong project id, or a cluster
  this mesh is not scheduled onto.
- **503 `upstream connect error or disconnect/reset before headers`**: that is
  Envoy. The gateway exists and routes; the pods behind it are not answering. A
  mesh that is deployed and unhealthy, or still starting.

Neither is a DNS answer. Ingestion and delivery are separate hosts on separate
clusters, so one can be healthy while the other is down: ingestion's
`/q/health` reporting `UP` says nothing about the edge.

## The console writes this repository too

The console's Mesh editor commits directly to the sourced branch, authored
`oidc:streamx:keycloak:<uuid> <unknown@streamx.com>`, with the message `Update
mesh/cloud-config.yaml`. Three consequences:

1. **It rewrites the whole file.** Every comment is dropped, and it writes its
   own shape (`overlay: {}` on each cluster). Reasoning that lives only in
   `cloud-config.yaml` comments will be deleted by the next console write; keep
   it in docs, and keep `overlay: {}` as the console writes it so its next write
   is not a diff.
2. **A console write is a deploy.** It lands on the sourced branch, so it
   redeploys like any merge, with no PR and no CI gate in front of it. Pull
   before branching: `develop`/`main` may have moved under you.
3. **A decision made only in git gets taken back.** Where git and the console
   disagree, the console is the side that provisions. Make the change in the
   console (or confirm it is reflected there), then mirror it here.

The Mesh editor also names the repository and branch a mesh is sourced from,
which is the quickest proof of which mesh you are looking at.

## Moving a mesh to another region

On 2026-11-24 an outage at the hosting provider behind StreamX's Paris region
(`eu-west-par-*`) left meshes there down for most of a day: the edge answered
503 for hours while ingestion in the same region still reported healthy. The way
out was to move the clusters. What that takes:

1. **Add the new clusters and disable the old ones**, in the console and in
   `cloud-config.yaml`. Disable with `enabled: false` rather than deleting the
   entry: that is the shape the console itself writes for a cluster it no longer
   schedules onto, so the file and the console stay in step.
2. **Move processing and edge together, or know why not.** Ingestion and
   delivery can be in different regions (each edge reads the channels from
   processing), but co-locating them keeps the hop short and gives an outage one
   region to take out rather than two.
3. **Update every consumer of the hostnames** in the same change window: the
   publishing repo's `STREAMX_INGESTION_URL` and `STREAMX_DELIVERY_URL`, and the
   CDN origin. Until the ingestion variable moves, publishes go to the old
   region. If the old region is down, they fail; if it is up, they succeed
   somewhere nobody reads.
4. **Expect the new edge to start from what the channels retain.** A new edge's
   stateful sinks cold-build their indexes from the channels on fresh volumes
   before they answer, so every document carries a `payload.ingested` from the
   moment it was rebuilt. Check the document count against the old edge, and
   re-publish the site if pages are missing.
5. **Watch both edges through the switch** with `scripts/search/watch_search.py`
   (two `--edge` flags), and confirm with a canary publish that the new
   ingestion host reaches the new edge.
6. **Check the ingestion token.** Tokens are issued per mesh; if a move ever
   comes with a new one, the `405`/`401` probe below tells you which you hold.

## Replicas

`cloud-config.yaml`'s `global.services` sets `replicas` per service. What two
months of measuring found:

- **`replicas: 1` cannot roll.** The platform's delivery disruption budget is
  `minAvailable: 1`; with one replica there is no room to take the pod down, so
  every push stops and restarts the service. Measured: **35 s of 503s** per
  deploy. StreamX's architect, asked directly (2026-09-16): fine for dev, not
  acceptable for prod; set the replica count to 2.
- **At 2, a deploy costs about 10 reader-seconds** (mean 10.2, range 4.1–14.5 s
  over six deploys). See [what a deploy costs](#what-a-deploy-costs).
- **Scaling up is free.** The 1 → 2 change itself produced 521 consecutive clean
  samples: the new replica built its whole index before it answered anything.
- **3 would not fix the remaining cost.** The degraded half scales as 1/N (about
  1 s of the 10); the blackout half does not.
- **Run `rest-ingestion` at 2 as well.** At 1, an ingestion roll fails every
  publish that lands in it: a red run, and a page left stale until republished.
- **Each replica of a stateful sink is a full, independent copy**, with its own
  index on its own volume. That is the design, and it has a cost: see [More than
  one replica](debugging-the-mesh.md#more-than-one-replica) in the debugging
  guide.

This repository's mesh still runs `replicas: 1`: fine for a reference mesh,
wrong for anything readers depend on.

## What a deploy costs

Polling `/search` twice a second through six deploys at two replicas, every
deploy had the same two-part shape:

| | duration | failure rate | what it is |
| --- | --- | --- | --- |
| **blackout** | 0.1–11.1 s | 100 % | every replica unserving at once |
| **degraded**, 29–58 s later | 6.5–7.0 s | ~50 % | one replica of two unavailable |

Two of six deploys had essentially no blackout, so its length is timing overlap
rather than a fixed cost. Every failure was the gateway's 503; an off-mesh
control never failed. Rolling `web-server-sink` alone cost the feeds nothing
measurable.

Measure your own with:

```bash
python3 scripts/search/watch_search.py --edge "$STREAMX_DELIVERY_URL" --minutes 30
```

Start it before merging, stop it with Ctrl-C after the roll. It prints a line
only when the status or the top-three ranking changes, then each edge's
searches, failures and longest outage: the number to put in the PR.

## serviceUnits

`serviceUnits.count` sizes each replica: **1 unit = 512 MiB and 250m CPU**,
shared by every container in the pod, including the injected `proxy` and the
`querier` every stateful service gets. At 1.0 the platform sets limits `{cpu: 1,
memory: 512Mi}` and requests `{cpu: 250m, memory: 512Mi}`.

Size each service at 1.5–2× its observed peak per-replica memory, from the
console's per-container metrics over a couple of weeks. Peaks measured on one
production mesh, for scale: `opensearch-sink` ~1.9 GB, `rendering-engine` ~1.3
GB, `sql-transformer` ~0.9 GB (its `querier` alone 728 MB), `web-server-sink`
~0.43 GB, producer ~0.11 GB, relay and ingestion ~0.06 GB.

Several of those peaks ran above a 512Mi limit at 1.0 without an OOM kill, so
the limit did not appear to bind every container. Until StreamX says otherwise,
size no service below its observed peak: if the limit does bind, a count under
a service's working set is an OOM loop, not a slowdown. A project also has
overall limits; sizes it cannot fit are accepted in git and never applied.

## A rollout can stop halfway

The Services page draws one square per **desired** replica. A green square is a
running pod (hover it for the name). An **amber square has no tooltip**,
flickers on the 15-second refresh, and has no entry in the log panel's replica
picker: it is a replica the service should have and does not. Nothing says so in
words.

Seen four times in October 2026, on three different services. Each time a
deploy rolled one replica and the other never came back, or a single-replica
service stopped outright. The survivor can keep serving the **previous** config.
StreamX tracked it as a known platform bug, fixed in a platform update later
that month, but recognise it if it recurs:

- **Only one replica's answers come back.** Each replica's index scores
  slightly differently, so ask the same search a dozen times and count the
  distinct top scores. Two values means two replicas; one value, on a service
  that should have two, means one is gone.

  ```bash
  for i in $(seq 12); do
    curl -s "$EDGE/search/eds-pages/?query=streamx&size=1" \
    | python3 -c 'import json,sys; print(json.load(sys.stdin)["hits"]["hits"][0]["_score"])'
  done | sort | uniq -c
  ```

- **The channel that service consumes grows a backlog** while every other
  channel stays near zero. (The opposite of the [zero-backlog
  trap](debugging-the-mesh.md#the-zero-backlog-trap): a missing replica keeps
  its subscription, so nothing drains it.)
- **One edge serves old behaviour** while another serves the new. Compare edges
  directly, not through the CDN.

**What to do: raise it with StreamX.** The console has no restart or redeploy
control. Do not push another change to force a roll: if the pod cannot be
scheduled (a volume that will not attach, no capacity on the node), the next
roll sticks the same way and can take the surviving replica with it. Give them
the project, cluster, service, the missing pod's name, the commit that triggered
the rollout and its time, and the backlog. Roll services that have a volume in
StreamX's working hours (Central European time), when they can restore one the
same day.

## The restart lever

A service that reads its config from a mounted file (`volumesFrom`) does not
necessarily restart when only that file changes, because a mounted ConfigMap is
not part of the pod spec. For the producer this matters more than most: it fails
silently (an XPath it does not support is an empty node set, with no error and
no log line) and exposes no health or version endpoint, so "never re-read the
config" and "re-read it, matched nothing" look identical.

The fix is an environment variable nothing reads, bumped in the same commit as
any change to that service's mounted config:

```yaml
    containers:
      processor:
        environment:
          # Bump with every change to configs/indexable-resources-producer.yaml.
          # Nothing reads it; changing it changes the pod spec, which rolls the pod.
          PRODUCER_RESTART_LEVER: "1"
```

To retire one, change the config without bumping it on a dev mesh, canary
publish, and confirm the new extraction reached the index.

## Migrations

`service-init` migrations run at **sink startup**, in version order, via
Elasticsearch Evolution. The basics are in [debugging-the-mesh.md](debugging-the-mesh.md#config-lives-in-more-places-than-you-expect);
the operational rules that follow from them:

- **Never edit a migration that has run, on any mesh.** Its checksum is
  re-validated at every start and the sink will not come up if it changed. A
  migration that ran only on dev still counts. Pin applied files by sha256 in a
  manifest and have CI fail a changed pin: a shared source file (a painless
  script embedded in more than one migration) can otherwise rewrite an applied
  file through a build step nobody meant to touch it.
- **Roll back by rolling forward**: a new migration re-registering the previous
  body. Same template id, so the later version replaces the earlier one.
- **The exception is a migration that failed.** A failing migration blocks every
  later one, leaving an index with no mapping, no pipeline and no templates,
  which presents as an empty search rather than an error. It never applied, so
  replacing that file is the right fix. If it failed on prod but ran on dev,
  revert the promotion on `main` instead and leave dev's copy byte for byte.
- **Read the sink's startup log before blaming anything else.** Painless is
  compiled when the pipeline is PUT, and `ignore_failure` does not cover compile
  errors, so a script error stops the migration run at startup.
- **No `{{` anywhere in painless embedded in a search template**, comments
  included: mustache renders it. No comments in `.http` files.
- **Analyzer and index-settings changes need a closed index.** A settings
  migration against the open index fails at startup and blocks everything after
  it. Adding a sub-field with a built-in analyzer is a mapping change and works
  on an open index, but existing documents get it only when re-published.
- **Keep each deploy to one migration change**, so a sink that fails to start
  has one suspect.

## Secrets

Encrypted secrets in `mesh/secrets/encrypted/` are sealed to **one project's**
key pair (each file is an RSA-2048 block). They cannot be copied to another
project: that mesh cannot decrypt them, and the service fails to start holding a
value nobody can read.

A reference to a secret file that does not exist also fails the service at
**startup**, which is where the migrations run, so it presents as an empty
search, not a missing secret. A mesh with no credentials to supply is safer
with no `environmentFrom: secrets:` block at all than with a dangling one.

## Tokens

Each mesh's ingestion token is a JWT for its `github` source, and one mesh
rejects another's. To check a token without sending anything, GET the
ingestion endpoint, which only accepts POST:

```bash
curl -s -o /dev/null -w '%{http_code}\n' -H "Authorization: Bearer $TOKEN" \
  "$STREAMX_INGESTION_URL/ingestion/v2/cloudevents"
```

`405` means the token was accepted; `401` means it was not. GitHub never shows a
secret's value, so a token cannot be recovered from the publishing repo's
secrets: ask whoever administers the StreamX project.

## Workflow variables: test the shape, not the presence

Gate jobs on `startsWith(vars.STREAMX_DELIVERY_URL, 'https://')`, never on `!=
''`. A variable left at a placeholder (`FPO`, `TODO-SET-ME`) is not empty: under
an emptiness test the job runs, hands the placeholder to curl as a host, and
fails. One publishing repo failed every publish for a site that way for days,
because non-empty read as configured.
