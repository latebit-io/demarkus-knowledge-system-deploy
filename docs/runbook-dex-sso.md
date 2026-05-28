# Dex SSO runbook

One-shot operator runbook for the GitHub-backed OIDC federation that
ArgoCD + OpenBao consume. Run once per env after `platform-dex`
reports Synced+Healthy.

## Prereqs

- Phase 6 (`runbook-openbao-seed.md`) + Phase 7b
  (`runbook-eso-openbao.md`) complete — `secret/` kv-v2 mount + ESO
  installed with a working `external-secrets` policy and k8s auth
  role.
- Admin access to GitHub org `latebit-io`.
- `bao` CLI on PATH; root token in your password manager.

## Step 1 — Create a GitHub OAuth App for Dex

GitHub OAuth Apps only permit one Authorization callback URL, so the
existing oauth2-proxy App can't be reused. Create a **second** one:

`https://github.com/organizations/latebit-io/settings/applications` →
**New OAuth App**

| Field | Value |
|---|---|
| Application name | `demarkus knowledge system SSO` |
| Homepage URL | `https://dex.knowledge.demarkus.io` |
| Authorization callback URL | `https://dex.knowledge.demarkus.io/callback` |

Register, then on the next screen:

1. Copy the **Client ID**
2. **Generate a new client secret** → copy immediately (shown once)

## Step 2 — Generate static client secrets for ArgoCD + OpenBao

Each app gets its own Dex client_secret (separate from the GitHub
one). Generate two random 32-byte values:

```sh
ARGOCD_CLIENT_SECRET=$(openssl rand -base64 32 | tr -d '=' | tr -- '+/' '-_')
OPENBAO_CLIENT_SECRET=$(openssl rand -base64 32 | tr -d '=' | tr -- '+/' '-_')

echo "ArgoCD: $ARGOCD_CLIENT_SECRET"
echo "OpenBao: $OPENBAO_CLIENT_SECRET"
# Keep both in your password manager — they're regenerable but
# rotation invalidates active sessions.
```

## Step 3 — Seed OpenBao

```sh
kubectl -n openbao port-forward svc/openbao 8200:8200 &
export BAO_ADDR=http://127.0.0.1:8200
export BAO_TOKEN=<root>
```

Three entries — one per Dex consumer:

```sh
bao kv put secret/dex/github-client \
  client_id="<from GitHub OAuth App>" \
  client_secret="<from GitHub OAuth App>"

bao kv put secret/dex/argocd-client \
  client_secret="$ARGOCD_CLIENT_SECRET"

bao kv put secret/dex/openbao-client \
  client_secret="$OPENBAO_CLIENT_SECRET"
```

Verify all three:

```sh
bao kv get secret/dex/github-client
bao kv get secret/dex/argocd-client
bao kv get secret/dex/openbao-client
```

## Step 4 — Extend the ESO policy

The `external-secrets` policy now needs read on the new path:

```sh
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
POLICY
```

Verify:

```sh
bao policy read external-secrets
```

## Step 5 — Force ESO to materialize the Dex + ArgoCD Secrets

```sh
kubectl -n dex annotate externalsecret dex-credentials \
  force-sync=$(date +%s) --overwrite
kubectl -n argocd annotate externalsecret argocd-oidc-client \
  force-sync=$(date +%s) --overwrite
```

After ~30s:

```sh
kubectl -n dex get externalsecret,secret/dex-credentials
kubectl -n argocd get externalsecret/argocd-oidc-client secret/argocd-oidc-client
# Both ExternalSecrets STATUS=SecretSynced, READY=True
# Both Secrets exist with the expected keys
```

Dex pod should now start (was stuck `CreateContainerConfigError`
waiting on `dex-credentials`):

```sh
kubectl -n dex get pods
# expect: dex-* Running 1/1
```

Smoke test the Dex discovery doc:

```sh
curl -sS https://dex.knowledge.demarkus.io/.well-known/openid-configuration | jq
# expect: issuer = https://dex.knowledge.demarkus.io,
# authorization_endpoint, token_endpoint, jwks_uri all present
```

## Step 6 — `tofu apply` the ArgoCD bootstrap

ArgoCD's chart values changed (oidc.config added, oauth2-proxy
annotations removed). Tofu manages ArgoCD's chart, so the values bump
needs a tofu apply:

```sh
cd /Users/fritz/latebit/demarkus-knowledge-system-deploy/tofu/envs/prod
tofu state list | grep -i argocd
tofu apply -target=module.<argocd-module-name>
```

After apply, the argocd-server pod rolls. Smoke test:

```sh
kubectl -n argocd get configmap argocd-cm -o yaml | grep -A 8 'oidc.config'
# expect to see the issuer + clientID block
```

Now `https://argocd.knowledge.demarkus.io` shows a "LOG IN VIA Dex"
button in addition to "LOG IN AS ADMIN." Clicking Dex redirects
through Dex → GitHub → back into ArgoCD with the user's GitHub
identity.

## Step 7 — Enable + configure OpenBao OIDC auth

```sh
bao auth enable oidc

bao write auth/oidc/config \
  oidc_discovery_url="https://dex.knowledge.demarkus.io" \
  oidc_client_id="openbao" \
  oidc_client_secret="$OPENBAO_CLIENT_SECRET" \
  default_role="admin"
```

Create a role that maps OIDC logins to OpenBao policies. For now,
single `admin` role mapped to a permissive policy:

```sh
bao policy write admin - <<'POLICY'
# Admin policy for OIDC-authed users. Grants full access to the kv
# mount + auth/token management. Tighten when there are multiple
# personas; team-based mapping uses `groups_claim` per role.
path "*" {
  capabilities = ["create", "read", "update", "delete", "list", "sudo"]
}
POLICY

bao write auth/oidc/role/admin \
  bound_audiences="openbao" \
  allowed_redirect_uris="https://openbao.knowledge.demarkus.io/ui/vault/auth/oidc/oidc/callback,http://localhost:8250/oidc/callback" \
  user_claim="email" \
  token_policies="admin" \
  oidc_scopes="openid,email,profile,groups" \
  ttl="8h"
```

Verify:

```sh
bao read auth/oidc/config
bao read auth/oidc/role/admin
```

## Step 8 — Verify end-to-end

Browser:

1. Visit `https://openbao.knowledge.demarkus.io/ui/`
2. The login dropdown should now show "OIDC" alongside "Token"
3. Select OIDC → click "Sign in with OIDC"
4. Dex picks up → GitHub OAuth → back to Dex → back to OpenBao UI
5. You should land in the OpenBao UI with a session token

CLI:

```sh
bao login -method=oidc role=admin
# Opens browser flow; on success returns a Vault token
bao token lookup
# expect: policies=[admin, default]
```

## Step 9 — Tear down

```sh
unset BAO_TOKEN BAO_ADDR ARGOCD_CLIENT_SECRET OPENBAO_CLIENT_SECRET
# Ctrl-C the port-forward.
```

## Operational notes

- **Rotating a Dex client_secret:** regenerate, `bao kv put secret/dex/<app>-client client_secret=<new>`, ESO refreshes within 1h or force-sync. Existing sessions stay valid until their id_token expires (24h by default).
- **Rotating the GitHub OAuth App secret:** regenerate in the GitHub OAuth App settings, `bao kv put secret/dex/github-client client_secret=<new>`, ESO refresh, Dex pod restart (kubelet picks up the env var change on rollover).
- **Adding a new admin:** add to the `latebit-io` GitHub org. No deploy change.
- **Adding a new OIDC consumer (e.g. Grafana):** add a static client block to `platform/dex/application.yaml`, add an ExternalSecret bridging its client_secret, seed `secret/dex/<name>-client` in OpenBao.
- **Team-based authorization:** Dex emits `groups` claims for each GitHub team the user belongs to (across orgs visible to the OAuth App). OpenBao OIDC roles can match on these via `groups_claim`; ArgoCD's `rbac.csv` can map team names to ArgoCD roles. Wire when there are multiple personas.

## What's deferred

- **ArgoCD RBAC.** OIDC currently authenticates everyone to ArgoCD's default `readonly` role. Wire `configs.rbac.policy.csv` with team → role mappings when there are real admins vs. observers.
- **OpenBao multi-role.** Single `admin` role maps every OIDC login to full access. Add per-team roles (`role/observers`, `role/engineers`, etc.) with bound `groups_claim` when role separation matters.
- **oauth2-proxy retirement.** Once Dex is the standard for admin auth, oauth2-proxy at `auth.knowledge.demarkus.io` is only useful for non-OIDC hosts. Reassess when adding the next admin app; if it speaks OIDC, drop oauth2-proxy entirely.
