# oauth2-proxy GitHub admin auth runbook

One-shot operator runbook for putting GitHub OAuth in front of the admin
UIs (argocd, and any future host under `*.knowledge.demarkus.io`).
Run once per env, after `platform-oauth2-proxy` lands as an Argo
Application (the manifests in `platform/oauth2-proxy/` ship the
Application + ExternalSecret; the runbook covers the GitHub-side setup
and the Secret Manager value that ESO bridges from).

## Prereqs

- Secret Manager + ESO working: `ClusterSecretStore` `gcp-sm` is Ready
  and the `oauth2-proxy-github-client` secret container exists
  (`tofu/modules/platform-iam`). See `runbook-secrets.md`.
- Admin access to GitHub org `latebit-io` (or whichever org you're
  gating admission on).
- `kubectl` and `gcloud` on PATH, with write access to Secret Manager.

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

## Step 2 — Store the values in Secret Manager

Generate a fresh cookie-encryption secret (32 bytes, base64url, no
padding, what oauth2-proxy expects):

```sh
COOKIE_SECRET=$(openssl rand -base64 32 | tr -d '=' | tr -- '+/' '-_')
```

Secret `oauth2-proxy-github-client` holds one JSON object with
`client_id`, `client_secret` (from the GitHub OAuth App) and
`cookie_secret`. Value via stdin, never on the command line:

```sh
printf '%s' "{\"client_id\":\"<id>\",\"client_secret\":\"<secret>\",\"cookie_secret\":\"$COOKIE_SECRET\"}" \
  | gcloud secrets versions add oauth2-proxy-github-client \
      --project <project> --data-file=-
```

The secret container and the `external-secrets` GSA's secretAccessor
binding come from `tofu/modules/platform-iam`. Verify and troubleshoot
per `runbook-secrets.md`.

## Step 3 — Force the ExternalSecret to sync

```sh
kubectl -n oauth2-proxy annotate externalsecret github-client \
  force-sync=$(date +%s) --overwrite
kubectl -n oauth2-proxy get externalsecret github-client
# expect STATUS=SecretSynced, READY=True
kubectl -n oauth2-proxy get secret github-client
# expect 3 data keys
```

## Step 4 — Verify the auth flow

Open `https://argocd.knowledge.demarkus.io` (or any other host gated by
oauth2-proxy) in a browser:

1. Should redirect to `https://auth.knowledge.demarkus.io/oauth2/start?rd=...`
2. Which redirects to GitHub for OAuth login
3. GitHub asks for `read:org` consent (first time per user)
4. Redirects back to `https://auth.knowledge.demarkus.io/oauth2/callback`
5. oauth2-proxy verifies `latebit-io` org membership
6. On success: sets a `_oauth2_proxy` cookie scoped to
   `.knowledge.demarkus.io` and redirects to the original `rd=` target
7. ingress-nginx now sees a valid cookie via `auth-url` → forwards to
   the upstream

Subsequent visits to any gated admin host within the cookie's lifetime
(default 168h) skip the OAuth dance entirely.

## Operational notes

- **Rotation:** to rotate the GitHub client_secret, generate a new one
  in the GitHub OAuth App settings, then add a new version of
  `oauth2-proxy-github-client` (all three keys; see `runbook-secrets.md`).
  ESO refreshes within 1h (or force-sync). Cookie
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
- **Per-host RBAC inside the apps.** ArgoCD has its own RBAC.
  oauth2-proxy gates *access* to the ingress,
  not what you can do once in. Future hardening could wire ArgoCD's
  OIDC config to read the `X-Auth-Request-User` header the ingress
  forwards.
