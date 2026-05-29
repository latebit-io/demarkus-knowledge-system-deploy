# Instantiate this template

Fork → your own live knowledge system. This is the orchestration guide; each
step links the runbook with the detail. Order matters.

This repo is a concrete deployment first, template second — so instantiating
means **replacing the hardcoded deployment-specific values** below, then walking
the bring-up. Budget a few hours, mostly waiting on DNS + ArgoCD sync.

## Prerequisites

- A GCP **org or folder** + a **billing account** (project creation needs
  org/folder-level rights).
- A **domain** you can delegate a subdomain of to Cloud DNS.
- A **GitHub org** (admin SSO federates its membership) + a GitHub OAuth app.
- A **Google OAuth client** (broker user login).
- Tools: `tofu >= 1.8`, `gcloud`, `kubectl`, `helm`, `bao` (OpenBao CLI).

## Values you must change

Find/replace across the repo — these are baked into manifests, not variables:

| Value | Replace with | Where |
|-------|--------------|-------|
| `knowledge.demarkus.io` | your domain | ~13 files under `platform/`, `apps/`, `tofu/modules/dns`, `bootstrap/` (find/replace) |
| `latebit-io/demarkus-knowledge-system-deploy` | your fork | `bootstrap/root-appset.yaml` (repoURL), `tofu/bootstrap/ci/variables.tf` (`github_repo`) |
| `knowledge-49722` | your project id | `platform/openbao/application.yaml` (gcpckms seal + SA annotation), `platform/external-dns/application.yaml` (SA annotation) |
| `latebit-knowledge-tofu-state` / `latebit-tofu-bootstrap` | your state bucket / bootstrap project | `tofu/envs/prod/backend.tf`, `tofu/bootstrap/ci/backend.tf` + `variables.tf` |
| `latebit-io` (Dex GitHub org) | your org | `platform/dex/external-secret.yaml` |
| Google OAuth `clientID` | yours | `apps/demarkus-broker/application.yaml` |
| Allowlisted emails / ACME email | yours | `apps/demarkus-broker/application.yaml`, `platform/cert-manager/cluster-issuers.yaml` |
| Worlds (`world-a`) | your worlds | `apps/demarkus-worlds/applicationset.yaml` (generators), `apps/demarkus-broker/application.yaml` (`worlds[]`) |

## Bring-up

1. **Bootstrap state** (chicken/egg). Create a bootstrap project + a GCS bucket
   for OpenTofu state (object versioning on, public-access-prevention enforced)
   in your region, by hand. Point `tofu/envs/prod/backend.tf` at it.

2. **Configure.** `cp tofu/envs/prod/terraform.tfvars.example
   tofu/envs/prod/terraform.tfvars` and fill `project_id`, `billing_account`,
   `org_id` *or* `folder_id`, `region`, `budget_alert_email`. (Gitignored —
   never commit it.)

3. **Apply the substrate.**
   ```sh
   gcloud auth login && gcloud auth application-default login
   cd tofu/envs/prod && tofu init && tofu apply
   ```
   Creates the project + APIs, VPC + Cloud NAT, Cloud DNS zone, GKE, ArgoCD +
   the root ApplicationSet, KMS + Workload Identity, and the budget alert.

4. **Delegate DNS.** Copy the Cloud DNS zone's NS records to your registrar for
   the subdomain and wait for propagation. cert-manager (Let's Encrypt HTTP-01)
   and external-dns both depend on this resolving.

5. **Let ArgoCD reconcile.** Watch `argocd.<your-domain>` (or `kubectl get app -n
   argocd`). Waves bring up cert-manager → OpenBao + bank-vaults → ingress +
   external-dns + ESO + Dex → broker + worlds + backups. It self-heals through
   the initial races.

6. **Seed OpenBao** (one-time, manual — auto-unseal is automatic via KMS, but
   init + secrets are not). Create the Google OAuth client first, then store the
   broker OIDC client secret, signing key, and world tokens.
   → [runbook-openbao-seed.md](runbook-openbao-seed.md). ESO then bridges these
   into k8s Secrets → [runbook-eso-openbao.md](runbook-eso-openbao.md).

7. **Admin SSO.** Wire Dex to your GitHub org + a GitHub OAuth app so the ArgoCD
   and OpenBao admin UIs are gated. → [runbook-dex-sso.md](runbook-dex-sso.md).

8. **CI (recommended).** Bootstrap WIF and set the GitHub Variables/Secrets so
   PRs plan and merges apply, with no JSON keys.
   → [runbook-ci-wif.md](runbook-ci-wif.md).

9. **Backups** run automatically (daily CSI snapshots). Do the restore drill
   once to prove it. → [runbook-backup-restore.md](runbook-backup-restore.md).

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
