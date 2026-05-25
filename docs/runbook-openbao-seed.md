# OpenBao seed runbook (Phase 6)

One-shot runbook to make OpenBao ready for the broker. Run once per env, by
a human, against an already-initialized + auto-unsealed OpenBao
(`platform/openbao/application.yaml` is the deployment).

After this completes, Phase 7 can install the broker chart with `vault:`
env refs and the bank-vaults webhook will fetch the secrets at pod start.

## Prereqs

- `kubectl` context is the GKE cluster (`gcloud container clusters
  get-credentials demarkus --zone northamerica-northeast2-a --project
  knowledge-49722`).
- `bao` CLI installed locally (https://openbao.org/docs/install/).
- 3 of the 5 OpenBao recovery keys from `bao operator init` are at hand
  (1Password or wherever they were stored on first init).
- A Google OAuth 2.0 Client ID exists in the `knowledge-49722` GCP project
  with authorized redirect URI `https://knowledge.demarkus.io/auth/callback`.
  Capture `client_id` + `client_secret`.

## Step 0 — Open a port-forward to OpenBao

OpenBao does not yet have an ingress (deferred). The bao CLI talks to it
through `kubectl port-forward` for the duration of this runbook:

```sh
kubectl -n openbao port-forward svc/openbao 8200:8200
```

In a second shell:

```sh
export BAO_ADDR=http://127.0.0.1:8200
bao status   # expect Sealed=false, Initialized=true
```

## Step 1 — Rotate the root token (pre-flight)

The original root token from `bao operator init` leaked into a prior chat
transcript. Rotate before seeding anything — the new root token is the
credential that authorizes Steps 2–4.

Auto-unseal is on (gcpckms), so the rotation flow uses **recovery keys**,
not unseal keys. You need 3 of the 5.

```sh
# Start the generate-root flow. Returns a nonce + a one-time pad (OTP).
bao operator generate-root -init
# → Nonce: <nonce>
# → OTP:   <otp>

# Submit 3 recovery keys (one per command), each referencing the nonce.
bao operator generate-root -nonce=<nonce> <recovery-key-1>
bao operator generate-root -nonce=<nonce> <recovery-key-2>
bao operator generate-root -nonce=<nonce> <recovery-key-3>
# → Final command prints "Encoded Token: <encoded>"

# XOR-decode the encoded token with the OTP to get the new root token.
bao operator generate-root -decode=<encoded> -otp=<otp>
# → New root token: <new-root>

# Verify the new token works, then revoke the old one.
export BAO_TOKEN=<new-root>
bao token lookup                       # expect policies=[root]
bao token revoke <old-root-token>      # the leaked one
```

Save the new root in your password manager. Do **not** put it in any
committed file, env file, or chat. Subsequent steps assume `BAO_TOKEN` is
exported to the new root.

## Step 2 — Run the seed script

`scripts/seed-openbao.sh` is idempotent. It checks current state before
each mutation, so re-running is safe.

```sh
# Generate the broker's id_token signing key (ECDSA P-256, PEM). Done once,
# locally, never committed. The script reads it from the file you pass.
openssl ecparam -name prime256v1 -genkey -noout -out /tmp/broker-signing.pem

# OAuth client credentials — paste from the Google OAuth client you created.
cat > /tmp/oidc-client.env <<'EOF'
client_id=REPLACE-ME.apps.googleusercontent.com
client_secret=REPLACE-ME
EOF

# Required env: BAO_ADDR + BAO_TOKEN already exported from Step 1.
./scripts/seed-openbao.sh \
  --oidc-env /tmp/oidc-client.env \
  --signing-key /tmp/broker-signing.pem

# Scrub the temp files.
shred -u /tmp/broker-signing.pem /tmp/oidc-client.env
```

What the script does:

1. Enables the Kubernetes auth method at `auth/kubernetes/` (if not
   already enabled) and configures `kubernetes_host=
   https://kubernetes.default.svc:443`. The token reviewer JWT is the
   pod's own service account token — no `token_reviewer_jwt` field is
   set, which makes OpenBao use the request's bound token to call
   `TokenReview` (the default since Kubernetes 1.21).
2. Ensures the `kv-v2` secrets engine is mounted at `secret/`. The
   OpenBao helm chart enables this by default; the script checks before
   enabling to stay idempotent.
3. Writes `secret/broker/oidc-client` with keys `client_id` +
   `client_secret`.
4. Writes `secret/broker/jwks-signing-key` with key `pem` set to the
   contents of the PEM file.
5. Writes a `broker` policy granting `read` on `secret/data/broker/*`.
6. Writes a Kubernetes auth role `broker` bound to KSA
   `demarkus-broker/demarkus-broker` (namespace/name) with the
   `broker` policy attached and TTL 1h.

The KSA + namespace don't exist yet — that's fine. The role is just a
mapping that activates when the broker pod authenticates in Phase 7.

## Step 3 — Verify

```sh
bao kv get secret/broker/oidc-client
bao kv get secret/broker/jwks-signing-key       # only key=pem; body shown
bao auth list                                    # kubernetes/ present
bao read auth/kubernetes/role/broker             # bound_sa names + policies
bao policy read broker                           # path "secret/data/broker/*" read
```

All five must succeed. If any does not, re-run the seed script — it
reports which step failed and exits non-zero.

## Step 4 — Tear down

```sh
unset BAO_TOKEN BAO_ADDR
# Ctrl-C the port-forward.
```

## What's deferred

- **In-cluster TLS for OpenBao.** Broker → OpenBao traffic in Phase 7
  rides the pod network unencrypted until the TLS-enable path in
  `platform/openbao/application.yaml` is flipped on. Worth doing before
  the broker handles real OAuth client secrets.
- **Per-world admin tokens (`secret/worlds/<name>/admin-token`).** The
  demarkus-server helm chart's bootstrap Job still generates these; the
  pivot to OpenBao for world tokens is its own slice in Phase 7.
- **HA OpenBao (3 replicas).** Still standalone+file. Master plan says
  scale before going live. One-time export → redeploy in HA Raft mode
  → import.
