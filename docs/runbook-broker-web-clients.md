# Runbook: registering a confidential web client with the broker

The broker supports **confidential web clients** (RFC 6749 §2.1) — server-side
web apps (e.g. a library reading room) that authenticate to the token endpoint
with a client secret and receive the authorization-code redirect at a real
https URL instead of a native-app loopback. The registry is operator-curated
via `webClients:` in `deployment.yaml`, templated into the broker chart by the
`apps/demarkus-broker/applicationset.yaml` git-files generator. Broker-side
mechanics: broker repo ADR 0001 (`docs/adr/0001-broker-confidential-web-clients.md`).

Native/CLI agents (Claude Code MCP SDK, demarkus-join) never appear here — no
registry entry means the unchanged public/PKCE loopback path.

## Customer-name policy

Same as the allowDomains runbook: no real client ids, hostnames, or hashes in
this repo's test fixtures or docs examples — only the production
`deployment.yaml`. Examples use RFC 2606 reserved domains.

## Registering a client

1. **Generate the secret** out of band, high-entropy:

   ```sh
   SECRET="$(openssl rand -hex 32)"
   ```

2. **Hash it** — only the sha256-hex goes into config; the plaintext lives in
   the web app's own deployment (its Secret / env), never in this repo:

   ```sh
   printf '%s' "$SECRET" | sha256sum | cut -d' ' -f1
   ```

   (macOS: `shasum -a 256` instead of `sha256sum`.)

3. **Edit `deployment.yaml`** — append to `webClients:`. Every entry must set
   ALL FOUR keys (`name` may be `""`): the ApplicationSet renders with
   `missingkey=error`, so an absent key fails the render rather than shipping
   a half-registered client.

   ```yaml
   webClients:
     - clientID: library-web
       clientSecretHash: "<64 hex chars from step 2>"
       redirectURIs:
         - https://library.example.com/auth/callback
       name: Example Library
   ```

   `redirectURIs` is an exact-match https allowlist — no wildcards, no
   loopback; the broker rejects any `redirect_uri` not listed.

4. **Open the PR.** The `broker-smoke` workflow runs
   `scripts/smoke-broker-web-clients.sh` (cluster-free render check: the
   registry survives AppSet goTemplate → chart → config Secret for the
   empty / single / multi cases).

5. **Hand the plaintext secret to the web app's deployment** (its own
   Secret store — not OpenBao here, not this repo).

## In-cluster: after a registry change lands

After the ArgoCD Application reports `Synced`:

```sh
# The rendered config Secret carries the registry.
kubectl -n demarkus-broker get secret demarkus-broker-config \
  -o jsonpath='{.data.config\.yaml}' | base64 -d | yq '.webClients'
```

The chart change is a config Secret change, not an immutable-field change —
the StatefulSet rolls automatically; apps-immutable-check does not apply.

End-to-end: log in through the web app. Expect the standard redirect SSO
round trip (authorize → Google → callback → app session). Negative checks:

- An unlisted `redirect_uri` on `/oauth/authorize` → request rejected.
- A wrong client secret at the token endpoint → `401 invalid_client`
  (and the authorization code is NOT burned — the app can retry after
  fixing its secret).

## Deregistering / rotating

- **Rotate:** generate a new secret, update `clientSecretHash` in
  `deployment.yaml` and the plaintext in the web app's deployment together.
  A mismatch window shows up as `401 invalid_client` on token/refresh.
- **Deregister:** remove the entry. Refresh tokens minted through a
  confidential exchange are bound to the `clientID`; once the registration
  is gone they fail at the refresh gate — no separate revocation sweep
  needed for that client's sessions (unlike the allowDomains note, which
  concerns unbound tokens).

## What the smoke does NOT cover

The broker code paths (secret verification, redirect allowlist enforcement,
refresh binding) are covered by the broker repo's behavioural tests
(`web_client_test.go`). The smoke only guards the deploy wiring: a chart bump
that drops the `webClients` rendering, or an AppSet edit that drops the
range, fails the PR instead of silently deploying an empty registry.
