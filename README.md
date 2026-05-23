# demarkus-knowledge-system-deploy

**Status: WIP.** Nothing here is live yet.

Public reference deployment of a [demarkus](https://github.com/latebit-io/demarkus)
knowledge system on GKE. The repo will also serve as a GitHub template so others
can stand up their own.

- **Hostname (target):** `knowledge.demarkus.io`
- **Cloud:** GCP / GKE Standard, single region (`us-central1`)
- **IaC:** [OpenTofu](https://opentofu.org/)
- **Secrets:** [OpenBao](https://openbao.org/) + bank-vaults webhook
- **GitOps:** ArgoCD + ApplicationSet, charts from `ghcr.io/latebit-io/charts`

Master plan: `mark://soul.demarkus.io/plans/knowledge-system-gke-deploy.md`.

## Layout (in progress)

```
tofu/
  modules/
    project/        # GCP project + API enablement
  envs/
    prod/           # knowledge.demarkus.io
```

## Prerequisites

Before running OpenTofu the first time:

1. Install OpenTofu `>= 1.8`.
2. Hand-create one GCS bucket for OpenTofu state in an existing project of
   yours. Object versioning **on**. Drop the bucket name into
   `tofu/envs/prod/backend.tf` (replace `REPLACE_ME`).
3. Copy `tofu/envs/prod/terraform.tfvars.example` to
   `tofu/envs/prod/terraform.tfvars` and fill in values. This file is
   gitignored — never commit it.
4. `gcloud auth application-default login` so the provider can authenticate
   locally. (CI will use Workload Identity Federation; not wired yet.)

## Phase 1 usage

```
cd tofu/envs/prod
tofu init
tofu plan
tofu apply
```

Phase 1 creates the GCP project and enables the APIs needed by later phases.
Nothing else exists yet.
