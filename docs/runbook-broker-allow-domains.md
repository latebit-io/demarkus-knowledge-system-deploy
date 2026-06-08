# Runbook: verifying the broker OIDC domain allowlist

The broker can be locked to one or more Google Workspace tenants via
`oidc.allowDomains` (gates every auth surface — `/auth/callback`,
`/oauth/authorize`, device flow — on the spoof-resistant `hd` claim, not the
email domain). The cluster-wide list lives in `deployment.yaml` under
`allowDomains:` and is templated into the broker chart by the
`apps/demarkus-broker/applicationset.yaml` git-files generator.

This runbook covers two checks: the PR-time render guard, and the optional
in-cluster end-to-end verification when the gate is first turned on or the
list is materially changed.

## Customer-name policy

Never put a real customer / tenant domain into this repo's test fixtures,
docs, or values examples — only the production `deployment.yaml`. The whole
point of the gate is org isolation; a tenant name leaking into the public
test surface defeats it. Examples below use the RFC 2606 reserved domains
(`example.com`, `example.org`, `example.net`).

## Pre-merge: `scripts/smoke-broker-allow-domains.sh`

Cluster-free render check. Renders the broker chart at the pinned version
against a synthetic `deployment.yaml` and asserts the chart turns
`allowDomains: [...]` into the rendered config Secret. Three cases: empty
(gate-open), single-domain, multi-domain.

```sh
bash scripts/smoke-broker-allow-domains.sh
```

Failure modes it catches:

- Chart bumped to a version that dropped the `oidc.allowDomains` rendering
  (the Secret no longer carries the key — the smoke fails loud rather than
  silently shipping a gate-open broker).
- The ApplicationSet's goTemplate values block dropped the `allowDomains`
  range (renders empty, gate-open) — assertion 2 + 3 fail.
- An unintended hardcoded domain in the chart values (assertion 2's
  forbid-pattern fires).

What it does NOT exercise: the broker code path that consumes the
`hd` claim. That's covered by the broker repo's unit + behavioural tests
(`TestOIDCDomainAllowed`, `TestOAuthAuthorizeAllowDomainsRejectsForeignHD`).

## In-cluster: after a list change lands

After the ArgoCD Application reports `Synced`, confirm the live broker booted
with the expected allowlist:

```sh
# 1. The rendered config Secret on the cluster carries the list.
kubectl -n demarkus-broker get secret demarkus-broker-config \
  -o jsonpath='{.data.config\.yaml}' | base64 -d | yq '.oidc.allowDomains'

# 2. The pod actually loaded it (the broker logs its effective allowDomains
#    at startup at info level).
kubectl -n demarkus-broker logs deploy/demarkus-broker | grep -i allowDomains
```

A real end-to-end gate test needs a Google identity outside the allowlist,
which can't be scripted in CI (no real id_token in the runner). Two options
when standing the gate up for the first time:

- **Self-test, in-allowlist:** log in via the broker's normal flow with a
  Workspace identity whose `hd` is in the allowlist — expect a successful
  redirect and a minted token. Confirms the gate doesn't lock out the
  intended tenants.
- **Negative test, out-of-allowlist:** log in with a consumer Gmail (`hd`
  absent) or a Workspace identity outside the allowlist — expect a 403
  ("domain not permitted") on `/auth/callback`, `error=access_denied` on
  `/oauth/authorize`, or a denied device grant. Confirms the gate is on.

If both pass, the rollout is verified. If only the negative test runs
(common when the operator is themselves out-of-allowlist), schedule the
self-test for someone inside the allowlist before declaring the rollout
done — a misconfigured allowlist that locks out everyone is recoverable
only by rolling back the deployment.

## Changing the list

The list is part of the cluster's identity; treat it like the admin
allowlist:

1. Edit `deployment.yaml` `allowDomains:`.
2. Open the PR. The smoke check runs in CI; reviewers confirm the diff is
   the intended tenant change.
3. After merge, ArgoCD rerenders the broker; the StatefulSet rolls
   automatically (the chart change is a config Secret + env change, not an
   immutable-field change — the apps-immutable-check workflow does NOT
   apply here).
4. Verify in-cluster per the section above before considering the change
   complete.

> Note on refresh tokens: the gate is enforced at every IdP exchange but
> NOT at refresh-token exchange. Identities that received a refresh token
> before a tenant was removed from the allowlist keep working until the
> refresh token is revoked. If a tenant removal needs immediate effect,
> revoke the outstanding refresh tokens through the broker's existing
> revoke surface — don't rely on the allowlist edit alone.
