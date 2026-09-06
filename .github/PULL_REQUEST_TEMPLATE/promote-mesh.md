<!--
Promotion PR: dev mesh -> prod mesh.

Use with ?template=promote-mesh.md

Merging this deploys to the production mesh. On 2026-09-06 a mesh change went
straight to the branch the live mesh sources from and stopped all indexing for
two and a half hours, with every service healthy and every workflow run green
throughout. The whole point of promoting through a dev mesh is that the same
change breaks somewhere cheap first — but only if someone actually looks.

Every box below is something that was green, silent, or zero during that outage
while the pipeline was completely dead. None of them are ceremony.
-->

## What is changing

<!-- One paragraph. If mesh.yaml channel refs changed, say which, explicitly. -->

## Automated gates

- [ ] **Verify mesh** is green — every channel has a producer and a consumer
- [ ] **Verify StreamX actions** is green — allow-list safety, install, resolution
- [ ] If `mesh.yaml` `incoming`/`outgoing` refs changed, the wiring diff is stated above in words

## The dev mesh is actually healthy

Not "deployed". Healthy. These are different, and the difference is the whole
reason this template exists.

- [ ] **The dev mesh has indexed something recently.** Bucket the index's own
      freshness stamp — anything other than a recent bucket means indexing is
      stopped:

      curl -s --get --data-urlencode 'size=1000' \
        "$DEV_DELIVERY_URL/search/eds-pages/" \
      | python3 -c "import json,sys,collections; d=json.load(sys.stdin); \
        ts=[h['_source'].get('payload',{}).get('ingested','') for h in d['hits']['hits']]; \
        print(d['hits']['total']['value'],'docs'); \
        [print(' ',k,'->',v) for k,v in sorted(collections.Counter(t[:16] for t in ts if t).items())]"

- [ ] **A canary publish on the dev mesh reached the index** — published one page
      and confirmed a *changed* `payload.ingested`, not merely that the document
      exists. An existence check passes instantly on an already-indexed page no
      matter how long ingestion has been dead.
- [ ] **Every channel backlog on the dev mesh is zero, or explained.** Remember a
      channel with no subscriber also reports zero, so read this alongside the
      wiring check rather than instead of it. A *non-zero* backlog needs its time
      graph checked — one of ours had been stuck for a week and was unrelated.
- [ ] **`opensearch-sink` started cleanly on the dev mesh** — `service-init`
      migrations all `success=true` in its logs. They run at sink startup, in
      version order, and a failing one blocks every later migration.
- [ ] **The search template still projects `payload.ingested`** — without it every
      freshness check silently degrades to an existence check, and says so only in
      a warning that is easy to accept.

## If this PR adds or changes `service-init` migrations

- [ ] They ran on the dev mesh sink and reported success
- [ ] They do not edit an already-applied migration (checksums are validated)
- [ ] A fix for a *failing* migration replaces that file rather than following it

## Rollback

- [ ] Stated below: what to revert, and how you will know it worked

<!--
How you will know it worked is the important half. "Revert the commit" is not a
rollback plan if nothing tells you whether indexing resumed.
-->
