# Dex SSO runbook

One-shot operator runbook for the GitHub-backed OIDC federation that
ArgoCD consumes through Dex. Run once per env after `platform-dex`
reports Synced+Healthy.

## Prereqs

- Secret Manager + ESO working: `ClusterSecretStore` `gcp-sm` is Ready
  and the `dex-github-client` and `dex-argocd-client` secret containers
  exist (created by `tofu/modules/platform-iam`). See
  `runbook-secrets.md` for adding, rotating and verifying values.
- Admin access to GitHub org `latebit-io`.
- `gcloud` and `kubectl` on PATH, with write access to Secret Manager in
  the project.

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

## Step 2 — Generate the ArgoCD client secret

ArgoCD gets its own Dex client_secret (separate from the GitHub one):

```sh
ARGOCD_CLIENT_SECRET=$(openssl rand -base64 32 | tr -d '=' | tr -- '+/' '-_')
# Keep it in your password manager. It is regenerable, but rotation
# invalidates active sessions.
```

## Step 3 — Store the values in Secret Manager

Two secrets, one JSON object each (add `--project <project>`; values via
stdin, never on the command line):

| Secret ID | Keys |
|---|---|
| `dex-github-client` | `client_id`, `client_secret` (from the GitHub OAuth App) |
| `dex-argocd-client` | `client_secret` (`$ARGOCD_CLIENT_SECRET`) |

```sh
printf '%s' '{"client_id":"<id>","client_secret":"<secret>"}' \
  | gcloud secrets versions add dex-github-client --project <project> --data-file=-

printf '%s' "{\"client_secret\":\"$ARGOCD_CLIENT_SECRET\"}" \
  | gcloud secrets versions add dex-argocd-client --project <project> --data-file=-
```

Verify with the checks in `runbook-secrets.md`.

## Step 4 — Force ESO to materialize the Dex + ArgoCD Secrets

```sh
kubectl -n dex annotate externalsecret dex-config \
  force-sync=$(date +%s) --overwrite
kubectl -n argocd annotate externalsecret argocd-oidc-client \
  force-sync=$(date +%s) --overwrite
```

After ~30s:

```sh
kubectl -n dex get externalsecret/dex-config secret/dex-config
kubectl -n argocd get externalsecret/argocd-oidc-client secret/argocd-oidc-client
# Both ExternalSecrets STATUS=SecretSynced, READY=True
# Both Secrets exist with the expected keys
```

Dex reads its config only at startup. Restart it so it picks up the
`dex-config` Secret:

```sh
kubectl -n dex rollout restart deploy/dex
kubectl -n dex get pods
# expect: dex-* Running 1/1
```

Smoke test the Dex discovery doc:

```sh
curl -sS https://dex.knowledge.demarkus.io/.well-known/openid-configuration | jq
# expect: issuer = https://dex.knowledge.demarkus.io,
# authorization_endpoint, token_endpoint, jwks_uri all present
```

## Step 5 — `tofu apply` the ArgoCD bootstrap

ArgoCD's chart values changed (oidc.config added, oauth2-proxy
annotations removed). Tofu manages ArgoCD's chart, so the values bump
needs a tofu apply. From the repo root:

```sh
cd tofu/envs/prod
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

## Step 6 — Verify end-to-end

1. Visit `https://argocd.knowledge.demarkus.io`
2. Click "LOG IN VIA Dex"
3. Dex → GitHub OAuth → back to Dex → back to ArgoCD
4. You land in the ArgoCD UI as your GitHub identity

## Step 7 — Tear down

```sh
unset ARGOCD_CLIENT_SECRET
```

## Operational notes

- **Rotating a Dex client_secret:** generate a new value, add a new version to the secret (`dex-argocd-client` or `dex-github-client`, see `runbook-secrets.md`), force-sync the ExternalSecret (ESO refreshes within 1h otherwise), then restart Dex. Existing sessions stay valid until their id_token expires (24h by default).
- **Rotating the GitHub OAuth App secret:** regenerate in the GitHub OAuth App settings, add a new version of `dex-github-client` with both keys (`client_id`, `client_secret`), force-sync, restart Dex.
- **Adding a new admin:** add to the `latebit-io` GitHub org. No deploy change.
- **Adding a new OIDC consumer (e.g. Grafana):** add a static client block to `platform/dex/application.yaml`, add an ExternalSecret bridging its client_secret from a new `dex-<name>-client` Secret Manager secret (container in `tofu/modules/platform-iam`, secretAccessor for the `external-secrets` GSA), then set its value per `runbook-secrets.md`.
- **Team-based authorization:** Dex emits `groups` claims for each GitHub team the user belongs to (across orgs visible to the OAuth App). ArgoCD's `rbac.csv` can map team names to ArgoCD roles. Wire when there are multiple personas.

## What's deferred

- **ArgoCD RBAC.** OIDC currently authenticates everyone to ArgoCD's default `readonly` role. Wire `configs.rbac.policy.csv` with team → role mappings when there are real admins vs. observers.
- **oauth2-proxy retirement.** Once Dex is the standard for admin auth, oauth2-proxy at `auth.knowledge.demarkus.io` is only useful for non-OIDC hosts. Reassess when adding the next admin app; if it speaks OIDC, drop oauth2-proxy entirely.
