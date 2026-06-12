# Runbook: deploying the Universe Library (demarkus-library)

The library (`apps/demarkus-library`) is GitOps-managed like every other app —
merge to main and ArgoCD converges it. What it CANNOT do by itself is read its
OAuth client secret: the plaintext lives in OpenBao, bridged by ESO, and the
OpenBao side needs a one-time manual seed (same posture as the broker's
secrets — docs/runbook-eso-openbao.md).

Registration recap (see docs/runbook-broker-web-clients.md): the broker holds
the **sha256** of the secret in `deployment.yaml`'s `webClients[]`
(`clientID: library-web`); the library pod needs the **plaintext** as
`DEMARKUS_CLIENT_SECRET`. This runbook puts the plaintext where ESO can reach
it.

## Step 1 — Widen the ESO policy

The `external-secrets` policy (runbook-eso-openbao.md §Step 1) grants per-app
prefixes under `secret/data/`. Add the library's. Policy writes replace the
whole document, so re-write it with all current paths:

```sh
kubectl -n openbao port-forward svc/openbao 8200:8200   # shell 1
export BAO_ADDR=http://127.0.0.1:8200                   # shell 2
export BAO_TOKEN=<root-or-admin-token>

bao policy write external-secrets - <<'POLICY'
path "secret/data/broker/*" {
  capabilities = ["read"]
}
path "secret/data/oauth2-proxy/*" {
  capabilities = ["read"]
}
path "secret/data/dex/*" {
  capabilities = ["read"]
}
path "secret/data/library/*" {
  capabilities = ["read"]
}
POLICY
```

(Check `bao policy read external-secrets` first — if the live policy has
paths beyond the three pre-existing ones (broker, oauth2-proxy, dex), carry
the extras forward along with the new library path.)

## Step 2 — Seed the client secret

The plaintext is the secret whose sha256 is `webClients[0].clientSecretHash`
in `deployment.yaml`. It was generated at registration time
(runbook-broker-web-clients.md §Step 1) and lives in the operator's password
manager. Verify the pairing before writing:

```sh
printf '%s' "$SECRET" | shasum -a 256 | cut -d' ' -f1
# must equal deployment.yaml's clientSecretHash for clientID library-web
```

```sh
bao kv put secret/library/oauth-client client_secret="$SECRET"
```

If the plaintext is lost, rotate instead: generate a new secret, update
`clientSecretHash` in `deployment.yaml` and this OpenBao entry together
(runbook-broker-web-clients.md §Deregistering / rotating).

## Step 3 — Verify

```sh
bao kv get secret/library/oauth-client          # key client_secret present
bao policy read external-secrets                 # secret/data/library/* read

unset BAO_TOKEN BAO_ADDR                         # then Ctrl-C the port-forward
```

After the apps-demarkus-library Application syncs:

```sh
# ESO materialized the Secret (SecretSynced=True).
kubectl -n demarkus-library get externalsecret library-oauth-client
# Pod is up — it refuses to start if DEMARKUS_CLIENT_SECRET is missing.
kubectl -n demarkus-library get pods
```

End-to-end: open `https://library.knowledge.demarkus.io/` → expect the
redirect SSO round trip (authorize → Google → callback → reading room at
root's `/index.md`). `401 invalid_client` at the callback means the OpenBao
plaintext and deployment.yaml's hash have drifted — re-pair them (Step 2).

## Notes

- **No new Google OAuth config.** The library is a client of the *broker*,
  not of Google; the broker's existing Google client covers the IdP leg.
- **ESO store reuse.** The ExternalSecret rides the cluster-scoped `openbao`
  ClusterSecretStore from apps/demarkus-broker — by design (it's
  cluster-scoped so future apps reuse it). Per-app store isolation is the
  same deferred option noted in runbook-eso-openbao.md.
- **Single replica.** Sessions are in-memory; >1 replica produces login
  loops. The chart value is pinned in the ApplicationSet with the rationale.
