# oauth2-proxy GitHub admin auth runbook

One-shot operator runbook for putting GitHub OAuth in front of the admin
UIs (argocd, openbao, and any future host under `*.knowledge.demarkus.io`).
Run once per env, after `platform-oauth2-proxy` lands as an Argo
Application (the manifests in `platform/oauth2-proxy/` ship the
Application + ExternalSecret; the runbook covers the GitHub-side setup
and the OpenBao seed that ESO bridges from).

## Prereqs

- Phase 6 (`runbook-openbao-seed.md`) and Phase 7b
  (`runbook-eso-openbao.md`) are complete — kv-v2 at `secret/`, ESO
  installed with a working kubernetes-auth role.
- Admin access to GitHub org `latebit-io` (or whichever org you're
  gating admission on).
- `kubectl` + `bao` CLI on PATH (or shell into `openbao-0` for `bao`).

## Step 1 — Create the GitHub OAuth App

Decision: under org account or your personal account?

- **Org account** (recommended): visible to all org admins, easier to
  hand off ownership later. Go to
  `https://github.com/organizations/latebit-io/settings/applications` →
  **New OAuth App**.
- **Personal account**: only you can edit it. Go to
  `https://github.com/settings/developers` → **New OAuth App**.

Fill in:

- **Application name:** `demarkus knowledge system admin`
- **Homepage URL:** `https://auth.knowledge.demarkus.io`
- **Authorization callback URL:** `https://auth.knowledge.demarkus.io/oauth2/callback`
- (Leave the rest blank / default.)

Click **Register application**. On the next screen:

1. Note the **Client ID** (public, fine to log).
2. Click **Generate a new client secret** → copy the value immediately
   (shown once).

If you want the OAuth App to read org membership without the user
having to grant read:org during login, enable **Request user
authorization (OAuth) during installation** on the org App settings.
Otherwise the first login will prompt the user to authorize the
`read:org` scope; this is fine, just an extra click.

## Step 2 — Seed OpenBao

Port-forward + token from `runbook-openbao-seed.md` Step 0 / Step 1:

```sh
kubectl -n openbao port-forward svc/openbao 8200:8200 &
export BAO_ADDR=http://127.0.0.1:8200
export BAO_TOKEN=<root>
```

Generate a fresh cookie-encryption secret (32 bytes, base64url, no
padding — what oauth2-proxy expects):

```sh
COOKIE_SECRET=$(openssl rand -base64 32 | tr -d '=' | tr -- '+/' '-_')
```

Write the three fields:

```sh
bao kv put secret/oauth2-proxy/github-client \
  client_id="<from GitHub OAuth App>" \
  client_secret="<from GitHub OAuth App>" \
  cookie_secret="$COOKIE_SECRET"
```

Verify:

```sh
bao kv get secret/oauth2-proxy/github-client
```

## Step 3 — Extend the ESO policy

The `external-secrets` policy currently only allows `read` on
`secret/data/broker/*`. ESO needs to read `secret/data/oauth2-proxy/*`
too. Update the policy (the `bao policy write` command overwrites
existing — the new policy below is the full body):

```sh
bao policy write external-secrets - <<'POLICY'
path "secret/data/broker/*" {
  capabilities = ["read"]
}
path "secret/data/oauth2-proxy/*" {
  capabilities = ["read"]
}
POLICY
```

Verify:

```sh
bao policy read external-secrets
```

## Step 4 — Force the ExternalSecret to sync

```sh
kubectl -n oauth2-proxy annotate externalsecret github-client \
  force-sync=$(date +%s) --overwrite
kubectl -n oauth2-proxy get externalsecret github-client
# expect STATUS=SecretSynced, READY=True
kubectl -n oauth2-proxy get secret github-client
# expect 3 data keys
```

## Step 5 — Verify the auth flow

Open `https://argocd.knowledge.demarkus.io` (or
`https://openbao.knowledge.demarkus.io`) in a browser:

1. Should redirect to `https://auth.knowledge.demarkus.io/oauth2/start?rd=...`
2. Which redirects to GitHub for OAuth login
3. GitHub asks for `read:org` consent (first time per user)
4. Redirects back to `https://auth.knowledge.demarkus.io/oauth2/callback`
5. oauth2-proxy verifies `latebit-io` org membership
6. On success: sets a `_oauth2_proxy` cookie scoped to
   `.knowledge.demarkus.io` and redirects to the original `rd=` target
7. ingress-nginx now sees a valid cookie via `auth-url` → forwards to
   ArgoCD / OpenBao

Subsequent visits to either admin host within the cookie's lifetime
(default 168h) skip the OAuth dance entirely.

## Step 6 — Tear down

```sh
unset BAO_TOKEN BAO_ADDR
# Ctrl-C the port-forward.
```

## Operational notes

- **Rotation:** to rotate the GitHub client_secret, generate a new one
  in the GitHub OAuth App settings, then `bao kv put` overwrites the
  existing entry and ESO refreshes within 1h (or force-sync). Cookie
  secret rotation invalidates all active sessions — users will be
  redirected through GitHub on next request.
- **Adding admins:** add the user to the `latebit-io` org. No deploy
  change needed.
- **Adding admin hosts:** annotate the new ingress with the same
  `auth-url` / `auth-signin` headers (see `bootstrap/argocd-values.yaml`
  for the pattern). Cookie covers any host under
  `.knowledge.demarkus.io`.
- **Locking down to specific team:** add `--github-team=<slug>` (or
  `github_team` in the config block of `platform/oauth2-proxy/application.yaml`).
  Requires the GitHub OAuth App to have `read:org` scope.

## What's deferred

- **oauth2-proxy redis backing.** Currently uses cookie-only session
  storage — session is the cookie body. Switching to redis is a
  scale concern (large admin user base, very long sessions) that
  doesn't apply here.
- **Per-host RBAC inside the apps.** ArgoCD has its own RBAC; OpenBao
  has its own auth tokens. oauth2-proxy gates *access* to the ingress,
  not what you can do once in. Future hardening could wire ArgoCD's
  OIDC config to read the `X-Auth-Request-User` header the ingress
  forwards.
