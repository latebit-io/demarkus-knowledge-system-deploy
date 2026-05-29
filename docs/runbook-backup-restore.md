# Runbook: Backups & Restore (Phase 9)

Stateful data lives on RWO Persistent Disks. We back it up with **CSI
VolumeSnapshots** (crash-consistent GCE PD snapshots) on a daily schedule —
no restic, no buckets, no IAM. The whole mechanism is GitOps manifests under
`apps/backups/`; the `pd.csi` driver does the snapshot work under GKE's own
managed service agent.

## What's backed up

A daily CronJob (`backups/demarkus-backup`, 02:00 America/Toronto) snapshots
**every PVC in any namespace labeled `demarkus.io/backup=true`**:

- `world-a/content-world-a-0` — world content + hash chain (the crown jewels)
- `openbao/data-openbao-0` — KMS-sealed secrets store
- `openbao/audit-openbao-0` — audit log

World namespaces get the label automatically from the worlds ApplicationSet's
`managedNamespaceMetadata`, so **every future world is backed up with no extra
config**. The openbao namespace is labeled the same way.

Retention is **age-based, `RETENTION_DAYS=30`** (env on the CronJob): snapshots
older than the cutoff are pruned, and the class's `deletionPolicy: Delete`
removes the underlying GCE snapshot too. This is NOT grandfather-father-son —
if you want 7d/4w/6m tiered retention, replace the CronJob with the
`snapscheduler` operator (Backube, Apache-2.0), which does GFS natively.

### Known gaps (deliberate)

- **`world-*-tokens` Secrets are NOT backed up.** Per-mint hash entries the
  broker appends live in a k8s Secret (etcd), not on a PVC, so snapshots miss
  them. Recovery: the demarkus-server chart's bootstrap Job re-creates the
  admin token; previously-minted user tokens are lost and users re-join via
  `/knowledge-join`. Backing these up would require a GCS bucket + Workload
  Identity (the plumbing the snapshot approach avoids) or GKE Backup for GKE.
- **`content-world-a-demarkus-server-0`** is an orphaned PVC from before
  `fullnameOverride` was set — not attached to any pod. The CronJob will
  snapshot it until it's cleaned up: `kubectl delete pvc -n world-a
  content-world-a-demarkus-server-0` (confirm it's unbound first).
- **CMEK**: snapshots inherit the source disk's encryption (Google-managed
  keys today). Client-controlled CMEK off the `demarkus-platform` KMS key would
  require recreating the source disks with a CMEK StorageClass — not done here.

## Operating

List managed snapshots and their readiness:

```sh
kubectl get volumesnapshot -A -l app.kubernetes.io/managed-by=demarkus-backup
# READYTOUSE should be true; SOURCEPVC names the volume.
```

Run a backup on demand (don't wait for 02:00):

```sh
kubectl create job -n backups --from=cronjob/demarkus-backup backup-adhoc-$(date +%s)
kubectl logs -n backups -l job-name --tail=-1 -f
```

## Restore drill (do this periodically — an untested backup isn't a backup)

Restore is "create a new PVC from a snapshot." The clone PVC must be in the
**same namespace** as the snapshot.

### Restore a world's content to a scratch volume and verify

```sh
NS=world-a
SNAP=$(kubectl get volumesnapshot -n $NS \
  -l demarkus.io/source-pvc=content-world-a-0 \
  --sort-by=.metadata.creationTimestamp -o name | tail -1)
echo "restoring from $SNAP"

cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: restore-test
  namespace: $NS
spec:
  accessModes: ["ReadWriteOnce"]
  storageClassName: standard-rwo
  resources:
    requests:
      storage: 1Gi
  dataSource:
    name: ${SNAP#volumesnapshot.snapshot.storage.k8s.io/}
    kind: VolumeSnapshot
    apiGroup: snapshot.storage.k8s.io
EOF
```

Then mount `restore-test` in a throwaway pod (or a transient demarkus-server
pointed at it), and **verify the hash chain** over the restored content — that
end-to-end verification is the actual deliverable for Phase 9, not just the
snapshot existing. Tear down `restore-test` afterward.

### Restore OpenBao

OpenBao's data is sealed; restoring `data-openbao-0` from a snapshot is safe
because auto-unseal uses the same KMS key (`demarkus-platform/openbao-unseal`),
which is **not** in the snapshot. Procedure: scale the `openbao` StatefulSet to
0, replace its PVC with one restored from the snapshot, scale back to 1; it
auto-unseals via gcpckms. (For routine OpenBao DR, prefer this over hand-editing
the file backend.)

## Failure modes

- CronJob pod `Pending` / image pull fails: the image is `alpine/k8s:<tag>`
  pinned in `apps/backups/cronjob.yaml`; bump the tag if the pull fails.
- Snapshot stuck `READYTOUSE=false`: check the `external-snapshotter`
  controller and the pd.csi driver; GKE manages both.
- No namespaces found: confirm the target namespaces carry
  `demarkus.io/backup=true` (`kubectl get ns -L demarkus.io/backup`).
