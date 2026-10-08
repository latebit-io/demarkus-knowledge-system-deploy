# Runbook: deploying the Universe Library (demarkus-library)

The library (`apps/demarkus-library`) is GitOps-managed like every other app —
merge to main and ArgoCD converges it. What it CANNOT do by itself is read its
OAuth client secret: the plaintext lives in GCP Secret Manager (secret
`library-oauth-client`), bridged by ESO, and the value needs a one-time manual
set (same posture as the broker's secrets, see docs/runbook-secrets.md).

Registration recap (see docs/runbook-broker-web-clients.md): the broker holds
the **sha256** of the secret in `deployment.yaml`'s `webClients[]`
(`clientID: library-web`); the library pod needs the **plaintext** as
`DEMARKUS_CLIENT_SECRET`. This runbook puts the plaintext where ESO can reach
it.

## Step 1 — Set the client secret

The `library-oauth-client` secret container and the `external-secrets` GSA's
secretAccessor binding come from `tofu/modules/platform-iam`; only the value is
manual. The plaintext is the secret whose sha256 is
`webClients[0].clientSecretHash` in `deployment.yaml`. It was generated at
registration time (runbook-broker-web-clients.md §Step 1) and lives in the
operator's password manager. Verify the pairing before writing:

```sh
printf '%s' "$SECRET" | shasum -a 256 | cut -d' ' -f1
# must equal deployment.yaml's clientSecretHash for clientID library-web
```

The secret is one JSON object with key `client_secret`; value via stdin:

```sh
printf '%s' "{\"client_secret\":\"$SECRET\"}" \
  | gcloud secrets versions add library-oauth-client \
      --project <project> --data-file=-
```

If the plaintext is lost, rotate instead: generate a new secret, update
`clientSecretHash` in `deployment.yaml` and this Secret Manager entry together
(runbook-broker-web-clients.md §Deregistering / rotating).

The library's LLM key is a separate secret, `library-llm` (key
`minimax_api_key`), set the same way. Add/rotate/verify details:
`runbook-secrets.md`.

## Step 2 — Verify

After the apps-demarkus-library Application syncs:

```sh
# ESO materialized the Secret (SecretSynced=True).
kubectl -n demarkus-library get externalsecret library-oauth-client
# After a new secret version, force a sync instead of waiting up to 1h:
#   kubectl annotate externalsecret library-oauth-client -n demarkus-library \
#     force-sync=$(date +%s) --overwrite
# Pod is up — it refuses to start if DEMARKUS_CLIENT_SECRET is missing.
kubectl -n demarkus-library get pods
```

End-to-end: open `https://library.knowledge.demarkus.io/` → expect the
redirect SSO round trip (authorize → Google → callback → reading room at
root's `/index.md`). `401 invalid_client` at the callback means the Secret
Manager plaintext and deployment.yaml's hash have drifted — re-pair them
(Step 1).

## Notes

- **No new Google OAuth config.** The library is a client of the *broker*,
  not of Google; the broker's existing Google client covers the IdP leg.
- **ESO store reuse.** The ExternalSecret rides the cluster-scoped `gcp-sm`
  ClusterSecretStore in platform/external-secrets (Workload Identity, GSA
  `external-secrets`) — by design, so every app reuses it. Access is granted
  per secret (secretAccessor), so adding a secret means adding its binding in
  tofu.
- **Single replica.** Sessions are in-memory; >1 replica produces login
  loops. The chart value is pinned in the ApplicationSet with the rationale.
