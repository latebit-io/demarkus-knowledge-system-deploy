# Instantiate this template

Fork → your own live knowledge system. One script drives it; the deployment
identity lives in a single file. Budget a few hours, mostly waiting on DNS +
ArgoCD sync.

## Prerequisites

- A GCP **org or folder** + a **billing account** (project creation needs
  org/folder-level rights).
- A **domain** you can delegate a subdomain of to Cloud DNS.
- A **GitHub org** (admin SSO federates its membership) + a GitHub OAuth app.
- A **Google OAuth client** (broker user login).
- Tools: `tofu >= 1.8`, `gcloud`, `kubectl`, `helm`, `yq`, `bao` (OpenBao CLI).

## The one-command path

```sh
gcloud auth login && gcloud auth application-default login
bash scripts/instantiate.sh
```

`instantiate.sh` is **phased, idempotent, and safe to re-run** — it resumes
where you left off:

1. **Config** *(automated)* — prompts for the deployment identity and writes it
   to **`deployment.yaml`** (committed, non-secret), the secret/substrate knobs
   to gitignored `terraform.tfvars`, points `backend.tf` at your state bucket,
   and runs `sync-deployment-config.sh` to propagate your fork's `repoURL` into
   every ApplicationSet generator. **This replaces the old find/replace.**
2. **Bootstrap state** *(gated)* — creates the bootstrap project + versioned GCS
   state bucket (the chicken/egg), only after you confirm.
3. **Substrate** *(gated)* — `tofu init`, shows the plan, applies on confirm:
   project + APIs, VPC + Cloud NAT, Cloud DNS, GKE, ArgoCD + the root
   ApplicationSet, KMS + Workload Identity, budget alert.
4. **Manual gates** *(guided)* — pauses with exact pointers for the steps that
   can't be safely automated (below).
5. **Verify** — curls the broker's RFC 8414 metadata.

## Where the deployment identity lives

| File | What | Committed? |
|------|------|-----------|
| **`deployment.yaml`** | domain, projectId, region, repoURL, githubOrg, oauthClientId, adminEmails, dnsTxtOwnerId, **worlds[]** | yes (non-secret) |
| `tofu/envs/prod/terraform.tfvars` | billing account, org/folder, project name, budget email | no (gitignored) |
| `tofu/{envs/prod,bootstrap/ci}/backend.tf` | state bucket (chicken/egg — set before `tofu init`) | yes (path only) |

Everything else — the broker, every world, the agent, dex/oauth2-proxy/
external-dns/openbao, the cert-manager issuers — renders from `deployment.yaml`.
**Adding a world is one entry in `deployment.yaml`'s `worlds[]`.** Edit the file
and re-run `scripts/sync-deployment-config.sh` (or `instantiate.sh`) any time.

## Manual steps (the script pauses for these)

These need a human at a console; the script guides you and links the runbook:

- **Delegate DNS** — copy the Cloud DNS zone's NS records to your registrar for
  your subdomain and wait for propagation (cert-manager + external-dns need it).
- **Seed OpenBao** — create the Google OAuth client first (redirect
  `https://broker.<domain>/auth/callback`), put its id in `deployment.yaml`'s
  `oauthClientId`, then init + seed OpenBao (broker OIDC secret, signing key,
  world tokens). → [runbook-openbao-seed.md](runbook-openbao-seed.md) (+
  `scripts/seed-openbao.sh`); ESO bridges them into k8s Secrets →
  [runbook-eso-openbao.md](runbook-eso-openbao.md).
- **Admin SSO** — wire Dex to your GitHub org + a GitHub OAuth app (callback
  `https://dex.<domain>/callback`) so the ArgoCD + OpenBao admin UIs are gated.
  → [runbook-dex-sso.md](runbook-dex-sso.md).
- **CI (recommended)** — bootstrap Workload Identity Federation so PRs plan and
  merges apply, with no JSON keys. → [runbook-ci-wif.md](runbook-ci-wif.md).
- **Backups** run automatically (daily CSI snapshots). Do the restore drill once
  to prove it. → [runbook-backup-restore.md](runbook-backup-restore.md).

## Verify

```sh
curl -s https://<your-domain>/.well-known/oauth-authorization-server | jq .
```

should return RFC 8414 metadata, and `/knowledge-join` from a Claude Code plugin
should complete the device flow end to end.

## Trim cost

Single env, single zonal cluster is the cheap default. To go lower: drop
`node_count`, use a smaller `machine_type`, or scale the cluster to zero when
idle. See the cost table in the [README](../README.md).
