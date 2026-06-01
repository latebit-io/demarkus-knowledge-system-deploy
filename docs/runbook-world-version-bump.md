# Runbook: bumping a world / server chart version

How to roll a `demarkus-server` (world) or `demarkus-broker` version, and how
to handle the one failure mode that needs a manual step.

## Normal bump

1. Confirm the new chart version exists in GHCR (the source of truth — see the
   `chart-version-source-of-truth` note; do not trust the monorepo Chart.yaml):
   ```sh
   TOKEN=$(curl -s "https://ghcr.io/token?scope=repository:latebit-io/charts/demarkus-server:pull&service=ghcr.io" | jq -r .token)
   curl -s -H "Authorization: Bearer $TOKEN" \
     "https://ghcr.io/v2/latebit-io/charts/demarkus-server/tags/list" | jq
   ```
2. Bump both `targetRevision` and the explicit `image.tag` in
   `apps/demarkus-worlds/applicationset.yaml` (worlds) or
   `apps/demarkus-broker/application.yaml` (broker).
3. Open the PR. The **apps-immutable-check** workflow renders the chart at the
   base and the head and flags any immutable StatefulSet field change (see
   below). A clean run means ArgoCD can apply the bump in place — merge and
   ArgoCD rolls it.

## The immutable-field trap

Kubernetes forbids in-place updates to a StatefulSet's `serviceName`,
`selector`, `podManagementPolicy`, or `volumeClaimTemplates`. If a chart bump
changes one of these, ArgoCD **cannot** reconcile it: the app shows
`sync=OutOfSync` with the operation `Failed`
(`StatefulSet ... is invalid: ... Forbidden`), and the pod stays on the old
spec while still serving. It does not self-heal.

The `apps-immutable-check` CI guard exists to catch this **on the PR**. If it
fails, the bump needs the manual recreate below as part of the rollout — plan
it, don't be surprised by it in prod.

> Note on `volumeMode`: the demarkus-server chart renders
> `volumeClaimTemplates[].spec.volumeMode: null`, which drifts from the
> `Filesystem` value Kubernetes defaults onto the live PVC. The worlds
> ApplicationSet absorbs this with `ignoreDifferences` on
> `/spec/volumeClaimTemplates` **plus** `RespectIgnoreDifferences=true` in
> `syncOptions` (the latter is required — `ignoreDifferences` alone still ships
> the field under ServerSideApply). The real fix is upstream: stop rendering a
> null `volumeMode`. Until then, keep both options on every world.

## Manual recreate (when an immutable field genuinely changed)

Non-destructive: the pod keeps running and the PVC is retained. Deleting the
StatefulSet object with `--cascade=orphan` leaves its pods; ArgoCD recreates
the StatefulSet at the new spec and adopts the running pod.

```sh
# 1. Delete only the StatefulSet API object (pod + PVC survive).
kubectl delete statefulset <name> -n <namespace> --cascade=orphan

# 2. Force ArgoCD to recreate it fresh at the new revision.
kubectl -n argocd annotate application <name> argocd.argoproj.io/refresh=hard --overwrite

# 3. Watch it roll.
kubectl rollout status statefulset/<name> -n <namespace>
kubectl get pod <name>-0 -n <namespace> \
  -o jsonpath='{.spec.containers[0].image} ready={.status.containerStatuses[0].ready}{"\n"}'
```

Verify the PVC stayed bound to the same volume throughout
(`kubectl get pvc -n <namespace>`). For a world, also confirm content is intact
(the restore-drill verification in `runbook-backup-restore.md` is the same idea).

This was first hit on the LOOKUP bump (server 0.17.11 → 0.17.13): the
`RespectIgnoreDifferences` fix prevents *future* steady-state wedges, but an
already-wedged StatefulSet still needed this one-time recreate.
