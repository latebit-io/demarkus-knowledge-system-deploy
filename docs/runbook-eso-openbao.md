# ESO ↔ OpenBao bridge runbook (Phase 7b)

One-shot runbook to wire the External Secrets Operator into OpenBao. Run
once per env, after the `platform-external-secrets` Argo Application is
Synced+Healthy. Separate from `runbook-openbao-seed.md` (Phase 6) because
the two operations happen at different times.

## Prereqs

- Phase 6 (`runbook-openbao-seed.md`) is complete — `auth/kubernetes/`
  enabled, `kv-v2` at `secret/`, broker secrets seeded.
- `platform-external-secrets` Application reports Synced+Healthy in
  ArgoCD. Verify with `kubectl -n external-secrets get pods`.
- `kubectl` context on the GKE cluster.
- `bao` CLI locally and the OpenBao root token from your password manager.

## Step 0 — Port-forward to OpenBao

```sh
kubectl -n openbao port-forward svc/openbao 8200:8200
```

In a second shell:

```sh
export BAO_ADDR=http://127.0.0.1:8200
export BAO_TOKEN=<root>
bao status   # expect Sealed=false, Initialized=true
```

## Step 0.5 — Confirm broker secrets exist

The ESO policy only grants `read` — the secrets themselves come from
Phase 6. If they're missing, ExternalSecret resources will reconcile to
`SecretSyncedError` until they're seeded. Catch that here:

```sh
bao kv get secret/broker/oidc-client       # expect key client_secret
bao kv get secret/broker/jwks-signing-key  # expect key pem
```

If either fails, stop and run `runbook-openbao-seed.md` (Phase 6) first.

## Step 1 — Write the ESO policy + auth role

```sh
bao policy write external-secrets - <<'POLICY'
path "secret/data/broker/*" {
  capabilities = ["read"]
}
# Extend as new apps need ESO-bridged secrets. Each app gets its own
# path prefix under secret/data/ so a misbehaving consumer of one
# can't read another's secrets. Current additions:
#   - oauth2-proxy/* (Phase 7c admin auth — see runbook-oauth2-proxy.md)
path "secret/data/oauth2-proxy/*" {
  capabilities = ["read"]
}
POLICY

bao write auth/kubernetes/role/external-secrets \
  bound_service_account_names="external-secrets" \
  bound_service_account_namespaces="external-secrets" \
  policies="external-secrets" \
  ttl="1h"
```

The role binds the ESO controller's KSA (`external-secrets/external-secrets`)
to the `external-secrets` policy. The policy grants `read` on the
broker's secret paths; extend it when new apps need their own paths
(or scope per-app with additional policies + roles).

## Step 2 — Verify

```sh
bao policy read external-secrets
bao read auth/kubernetes/role/external-secrets
```

Inside the cluster, the ExternalSecret resources reconcile within
~1 minute:

```sh
kubectl -n demarkus-broker get externalsecret
# NAME               STORE     REFRESH INTERVAL   STATUS         READY
# oidc-client        openbao   1h                 SecretSynced   True
# jwks-signing-key   openbao   1h                 SecretSynced   True

kubectl -n demarkus-broker get secret oidc-client jwks-signing-key
```

Note: the `demarkus-broker` namespace is created by Argo's
`CreateNamespace=true` when `apps-demarkus-broker` first syncs. If the
namespace doesn't exist yet, that Application hasn't reached the cluster
— check `kubectl get applications -n argocd`.

## Step 3 — Tear down

```sh
unset BAO_TOKEN BAO_ADDR
# Ctrl-C the port-forward.
```

## What's deferred

- **Per-app policy isolation.** All broker secrets share one
  `external-secrets` policy. Future apps that should not see each
  other's secrets need their own policy + role (and ESO can use
  per-namespace `SecretStore` instead of one shared `ClusterSecretStore`).
- **OpenBao TLS.** ESO → OpenBao traffic is plaintext on the pod
  network. Flip the TLS-enable path in
  `platform/openbao/application.yaml` to encrypt it.
