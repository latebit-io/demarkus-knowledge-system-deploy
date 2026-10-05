# Runbook: the commit-log rollout (knowledge 0.52.1 to 0.54.0)

Knowledge 0.54.0 stores every world as a create-only commit log (demarkus
ADR 0036). There is no migration from the 0.52.x format: a server that finds
an old-format bucket refuses to open it, so the rollout empties the world
buckets while nothing runs and every world starts again from genesis. Plan
and gate results: `mark://soul.demarkus.io/plans/bucket-commit-log-rollout.md`.

What changes for users: every world is empty afterwards (content, versions,
the federation graph). What does not change: worlds, writers, allowlists,
tokens, web clients, memory settings, DNS, certificates. The `bruno` world is
dropped, not recreated. Logins and MCP registrations live in the broker state
bucket, which is not touched.

Downtime: reads, writes and MCP sessions are down from the scale-down until
the new pods are ready, about an hour including the wipe.

## Before the window

1. Credentials: `gcloud auth login`, `gcloud config set project knowledge-49722`,
   and the GKE context for `kubectl`.

2. Take the `bruno` bucket out of OpenTofu state. `deployment.yaml` drives the
   per-world buckets through `for_each`, and the buckets carry
   `prevent_destroy`, so a plan that removes the world fails on the destroy.
   Run locally with owner credentials (see `runbook-ci-wif.md` for the local
   bootstrap):

   ```sh
   cd tofu/envs/prod && tofu init
   tofu state list | grep bruno
   tofu state rm 'module.knowledge_storage.google_storage_bucket.world["bruno"]' \
                 'module.knowledge_storage.google_storage_bucket_iam_member.knowledge_server["bruno"]'
   ```

   The bucket stays in GCP, orphaned; delete it by hand once its soft-deleted
   objects have aged out (step 10). Re-run the PR's `tofu-plan` afterwards; it
   must show no destroy.

3. Confirm the chart and image exist in GHCR (both listed 0.54.0 on 2026-10-05):

   ```sh
   TOKEN=$(curl -s "https://ghcr.io/token?scope=repository:latebit-io/charts/demarkus-knowledge-server:pull&service=ghcr.io" | jq -r .token)
   curl -s -H "Authorization: Bearer $TOKEN" https://ghcr.io/v2/latebit-io/charts/demarkus-knowledge-server/tags/list | jq .tags
   ```

4. Dry-list what the wipe removes. The static world buckets plus every memory
   tenant bucket; never `knowledge-49722-demarkus-broker-state`.

   ```sh
   WORLDS="root latebit ontehfritz music bruno"
   for w in $WORLDS; do echo "== $w"; gcloud storage ls "gs://knowledge-49722-demarkus-$w/**" | wc -l; done
   gcloud storage ls --project knowledge-49722 | grep '^gs://knowledge-49722-memory-'
   ```

## The window

5. Merge the rollout PR (pins to 0.54.0, `replicaCount: 0`, `bruno` removed).
   Argo scales the knowledge Deployment to zero and prunes the `bruno`
   objects; no pod starts on 0.54.0 yet. Confirm nothing runs:

   ```sh
   kubectl -n demarkus-knowledge get pods -l app.kubernetes.io/name=demarkus-knowledge-server
   ```

   Do not wipe while an old pod runs: an old server that opens an empty bucket
   recreates an old-format world.

6. Wipe objects only. The buckets stay, and soft delete keeps every removed
   object for 7 days.

   ```sh
   for w in $WORLDS; do gcloud storage rm "gs://knowledge-49722-demarkus-$w/**"; done
   for b in $(gcloud storage ls --project knowledge-49722 | grep '^gs://knowledge-49722-memory-'); do gcloud storage rm "${b}**"; done
   for w in $WORLDS; do echo "== $w"; gcloud storage ls "gs://knowledge-49722-demarkus-$w/**" | wc -l; done   # all 0
   ```

7. Open and merge the follow-up PR: `replicaCount: 3` in
   `apps/demarkus-knowledge-server/applicationset.yaml`, nothing else. The
   pods open every world, each logs `created a new world in an empty bucket`
   once per world (the second and third pods find the marker), write
   checkpoint zero and the seeded policy.

8. Verify:
   - 3 of 3 pods ready; `/readyz` green on each.
   - Logs: no `WARN` or `ERROR` beyond the first-open line; `world opened` for
     `root`, `latebit`, `ontehfritz`, `music` and every tenant; no `bruno`.
   - A FETCH of `/.well-known/demarkus/policy.md` on each world.
   - A Claude Code join through the knowledge gateway, then a `mark_fetch` and
     a `mark_publish` into `latebit`; the write visible from another replica
     within a second.
   - The library signs in and renders a page.
   - A memory tenant publish through `memory.demarkus.io`.
   - After a few writes, the federation deriver writes `/graph.md` into `root`.
   - Within 10 minutes of the first writes, `checkpoint written` in one pod's
     log per active world.

9. Re-promote the soul documents that lived in `latebit` (`/promote-scan` in
   the demarkus repo lists them; the promoted ones carry a `promoted:` line).

## After

10. Soak 24 hours: writer replica memory, `checkpoint written` on the cadence,
    no `checkpoint failed` or `reloading from the newest checkpoint`. Then
    delete the orphaned `bruno` bucket once `gcloud storage ls --soft-deleted`
    shows nothing left in it, and remove the `bruno` entries from OpenBao and
    the ExternalSecrets if any remain.

## Rollback (within 7 days)

Scale to zero as in step 5, restore the soft-deleted objects, pin back, scale up:

```sh
for w in $WORLDS; do gcloud storage restore "gs://knowledge-49722-demarkus-$w/**"; done
```

Then set `targetRevision` and `image.tag` back to 0.52.1 and `replicaCount`
to 3. After 7 days the old objects are gone and rollback means empty 0.52.1
worlds.
