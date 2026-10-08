# Secrets runbook (GCP Secret Manager + External Secrets)

All app secrets live in GCP Secret Manager in the project from
`deployment.yaml` (`projectId`). External Secrets Operator (ESO) copies them
into Kubernetes Secrets. Tofu creates the empty secret containers only; values
never enter tofu state or git.

Below, `<project>` is `projectId` from `deployment.yaml`.

## Layout and naming

Secret IDs cannot contain slashes, so paths are hyphenated. Each secret's value
is one JSON object; each ExternalSecret reads one key via `remoteRef.property`.

| Secret ID | JSON keys | Consumer |
|-----------|-----------|----------|
| `broker-oidc-client` | `client_id`, `client_secret` | broker (Google OIDC) |
| `broker-jwks-signing-key` | `pem` | broker id_token signing |
| `broker-memory-jwks-signing-key` | `pem` | archive only, no consumer |
| `library-oauth-client` | `client_secret` | library |
| `library-llm` | `minimax_api_key` | library |
| `oauth2-proxy-github-client` | `client_id`, `client_secret`, `cookie_secret` | oauth2-proxy |
| `dex-github-client` | `client_id`, `client_secret` | Dex (GitHub connector) |
| `dex-argocd-client` | `client_secret` | Dex static client for ArgoCD |

The list lives in `secret_manager_secrets`
(`tofu/modules/platform-iam/variables.tf`). Store: `ClusterSecretStore` `gcp-sm`
(`platform/external-secrets/cluster-secret-store-gcp.yaml`).

## Add, rotate, verify a value

Values go through stdin or a file, never the command line.

```sh
# first value or rotation: adds a new version
printf '%s' '{"client_id":"...","client_secret":"..."}' \
  | gcloud secrets versions add broker-oidc-client --project <project> --data-file=-
# or from a file
gcloud secrets versions add broker-oidc-client --project <project> --data-file=./value.json
```

Prefer a file or a prompt over `printf` with a literal so the value stays out of
shell history. `scripts/seed-secrets.sh` seeds the two broker secrets
(prompts for the OAuth client, generates the signing key) and skips any secret
that already has a version.

ESO refreshes every 1h (`refreshInterval: 1h`). Force it:

```sh
kubectl annotate externalsecret <name> -n <ns> force-sync=$(date +%s) --overwrite
```

Verify:

```sh
gcloud secrets versions list broker-oidc-client --project <project>   # version enabled
kubectl get externalsecret -A                                         # SecretSynced, READY True
kubectl -n demarkus-knowledge get secret oidc-client jwks-signing-key
```

Pods read Kubernetes Secrets at start. Restart the consumer after a rotation
(`kubectl rollout restart deploy/<name> -n <ns>`).

Rotating `broker-jwks-signing-key` invalidates every issued token. Only do it on
purpose; when migrating, copy the existing PEM byte for byte.

## Add a new secret end to end

1. Add the ID to `secret_manager_secrets` in
   `tofu/modules/platform-iam/variables.tf`. CI applies on merge: it creates the
   container and grants the ESO GSA `roles/secretmanager.secretAccessor` on it.
2. Add the first version with `gcloud secrets versions add` (JSON object).
3. Add an ExternalSecret:

```yaml
apiVersion: external-secrets.io/v1
kind: ExternalSecret
metadata:
  name: my-secret
  namespace: my-ns
spec:
  refreshInterval: 1h
  secretStoreRef: {name: gcp-sm, kind: ClusterSecretStore}
  target: {name: my-secret}
  data:
    - secretKey: client_secret
      remoteRef: {key: my-secret-id, property: client_secret}
```

Order matters: if the ExternalSecret syncs before the tofu apply or first
version, it shows `SecretSyncedError` and recovers on the next refresh (or force
sync).

## How ESO authenticates

Workload Identity, no keys:

- KSA `external-secrets/external-secrets` is annotated with
  `iam.gke.io/gcp-service-account: external-secrets@<project>.iam.gserviceaccount.com`.
- That GSA has `roles/secretmanager.secretAccessor` on each listed secret only
  (`tofu/modules/platform-iam/secret-manager.tf`), not project wide.
- `gcp-sm` is cluster scoped, so any namespace's ExternalSecret can name it. A
  secret is readable only if it is in the tofu list.

CI needs `roles/secretmanager.admin` on the project (`tofu/bootstrap/ci/main.tf`)
to manage those bindings. CI cannot grant itself roles, so apply the bootstrap
by hand from operator credentials.

## Troubleshooting

ClusterSecretStore not Valid:

```sh
kubectl describe clustersecretstore gcp-sm
kubectl -n external-secrets get sa external-secrets -o yaml | grep gcp-service-account
```

- Annotation missing or wrong GSA: fix in `platform/external-secrets`, sync.
- Workload Identity binding missing: check the `roles/iam.workloadIdentityUser`
  member `serviceAccount:<project>.svc.id.goog[external-secrets/external-secrets]`
  on the GSA (tofu `platform-iam`).
- `projectID`, cluster location or the ESO annotation differ from
  `deployment.yaml` (a fork): run `scripts/sync-deployment-config.sh`, commit.

ExternalSecret `SecretSyncedError`:

```sh
kubectl describe externalsecret <name> -n <ns>
```

- `Secret ... not found` / `NOT_FOUND`: container not created (tofu not applied,
  ID not in the list) or the ID in `remoteRef.key` is misspelled.
- `no versions` / `FAILED_PRECONDITION`: the secret has no enabled version.
  Add one.
- `PERMISSION_DENIED`: the ID is missing from `secret_manager_secrets`, or the
  tofu apply has not run.
- `property ... not found`: the JSON lacks that key, or the value is not a JSON
  object.

403 from CI (tofu apply on secrets):

- CI service account lacks `roles/secretmanager.admin`. Apply
  `tofu/bootstrap/ci` by hand from operator credentials, then re-run the job.

## Break-glass

Read or restore a value with operator credentials (needs
`secretmanager.versions.access`):

```sh
gcloud secrets versions access latest --secret <id> --project <project> > ./value.json   # chmod 600, delete after
gcloud secrets versions list <id> --project <project>
gcloud secrets versions enable <n> --secret <id> --project <project>   # roll back
```

Roll back a bad rotation by disabling the new version and enabling the old one,
then force sync. If ESO is down, create the Kubernetes Secret by hand with
`kubectl create secret generic ... --from-file`. Once ESO is healthy, delete
the manual Secret and force sync so ESO recreates and owns it. Never commit
values.
