# Runbook: CI via Workload Identity Federation (Phase 8)

GitHub Actions plans the prod env on every PR and applies it on merge to `main`,
authenticating to GCP with short-lived **Workload Identity Federation** tokens —
no long-lived JSON service-account keys exist anywhere.

- `tofu-plan.yml` — `pull_request` → `main`. Two jobs:
  - `validate` — runs for every PR (incl. forks); `fmt -check`, `init -backend=false`,
    `validate`. **No cloud credentials**, so untrusted fork code has nothing to abuse.
  - `plan` — **same-repo PRs only** (`head.repo.full_name == github.repository`);
    authenticates via WIF, `plan`, posts the plan as a sticky PR comment.
- `tofu-apply.yml` — `push` → `main` (i.e. after merge): `init`, `apply`.
  Concurrency group `tofu-apply-prod` serializes applies.

The identity infra lives in the **bootstrap project** (`latebit-tofu-bootstrap`),
not the prod project, so a `tofu destroy` on prod can never remove the identity
CI uses to manage it. It is its own tofu root: `tofu/bootstrap/ci/`, state prefix
`knowledge-system/ci-bootstrap` in the shared state bucket.

## One-time bootstrap (run locally, with owner creds)

```sh
gcloud auth login && gcloud auth application-default login

cd tofu/bootstrap/ci
cp terraform.tfvars.example terraform.tfvars
# Edit terraform.tfvars: set prod_project_id and billing_account.
# (bootstrap_project_id, github_repo, state_bucket, region have defaults.)

tofu init
tofu apply
```

This creates the WIF pool + provider, the `tofu-ci` service account, all the
grants the CI SA needs (state bucket, prod project, billing account), and
enables the IAM Service Account Credentials API on the bootstrap project (the
WIF token exchange needs it — without it, CI `init` fails with
`SERVICE_DISABLED`; the local apply doesn't hit it because it uses your own
creds, not the exchange). The
attribute condition pins the provider to **this repo only**, and the
`workloadIdentityUser` principalSet is scoped to the same repo.

Grab the two outputs — you'll paste them into GitHub next:

```sh
tofu output workload_identity_provider        # → WIF_PROVIDER
tofu output tofu_ci_service_account_email     # → WIF_SERVICE_ACCOUNT
```

## GitHub repo configuration

Settings → Secrets and variables → Actions.

**Variables** (non-sensitive):

| Name                  | Value                                                        |
| --------------------- | ----------------------------------------------------------- |
| `WIF_PROVIDER`        | `workload_identity_provider` output (full resource name)    |
| `WIF_SERVICE_ACCOUNT` | `tofu_ci_service_account_email` output                      |
| `TOFU_PROJECT_ID`     | prod project id (e.g. the value from `terraform.tfvars`)    |
| `TOFU_PROJECT_NAME`   | `Demarkus Knowledge System`                                 |
| `TOFU_ORG_ID`         | `630096686528`                                              |

**Secrets** (sensitive):

| Name                       | Value                                  |
| -------------------------- | -------------------------------------- |
| `TOFU_BILLING_ACCOUNT`     | billing account id (`XXXXXX-...`)      |
| `TOFU_BUDGET_ALERT_EMAIL`  | budget alert email                     |

`region`, `zone`, `dns_name`, `budget_amount`, `budget_currency` keep their
defaults in `tofu/envs/prod/variables.tf` — no Actions config needed.

## Verifying

1. Open a PR touching `tofu/**`. `tofu-plan` runs and comments the plan. A clean
   run against already-applied infra should show **no changes**.
2. Merge it. `tofu-apply` runs on `main` and applies (no-op if the plan was
   empty).

## CI SA permissions (least-privilege, not owner/editor)

Defined in `tofu/bootstrap/ci/main.tf`. State bucket: `storage.objectAdmin`.
Prod project: `compute.networkAdmin`, `container.admin` (also the cluster-admin
RBAC the helm/kubectl providers need), `dns.admin`,
`serviceusage.serviceUsageAdmin`, `iam.serviceAccountAdmin`,
`resourcemanager.projectIamAdmin`, `iam.serviceAccountUser`, `cloudkms.admin`.
Billing account: `billing.user` + `billing.costsManager` (budgets live at the
billing-account level, not the project).

## Notes & gotchas

- The GKE control plane is public (`enable_private_endpoint = false`, authorized
  networks `0.0.0.0/0`), so GitHub-hosted runners reach it directly — no
  self-hosted runner or VPN. If that's ever locked down, the in-cluster apply
  steps (argocd-bootstrap) will need a runner inside an authorized network.
- This eliminates the recurring local `tofu apply` + ADC-reauth toil for applies.
  Local applies still work for the bootstrap root and for break-glass.
- **Public-repo hardening.** This repo is public, so the CI is built to keep the
  CI SA's broad creds away from untrusted code and to keep sensitive values out
  of world-readable surfaces:
  - The authed `plan` job is gated to same-repo PRs; fork PRs only get the
    creds-free `validate` job.
  - Fork-PR workflows from outside collaborators require maintainer approval
    (`actions/permissions/fork-pr-contributor-approval` = `all_external_contributors`).
  - The plan PR comment redacts the billing-account and alert-email values
    (`TOFU_BILLING_ACCOUNT` / `TOFU_BUDGET_ALERT_EMAIL`) — Actions logs mask
    registered secrets, but API-posted comment bodies are not masked.
- Rotating trust: nothing to rotate — WIF tokens are short-lived per run. To
  revoke CI entirely, `tofu destroy` (or disable) the `tofu/bootstrap/ci` root.
