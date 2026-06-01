# Enterprise style demarkus knowledge system
Note: for teams or smaller needs this is overkill, you could get away with one or two deploys for 1% of the cost of k8s deploy. This use case is for at larger scale. 


A reference deployment of a [demarkus](https://github.com/latebit-io/demarkus)
knowledge system on GKE, managed entirely by GitOps. It doubles as a **GitHub
template** — fork it to stand up your own.

- **Cloud:** GCP / GKE Standard, single zonal cluster in `northamerica-northeast2` (Toronto)
- **IaC:** [OpenTofu](https://opentofu.org/) · **Secrets:** [OpenBao](https://openbao.org/) + bank-vaults · **GitOps:** ArgoCD · **Charts:** `ghcr.io/latebit-io/charts`

To run your own, see **[docs/instantiate.md](docs/instantiate.md)**.

## What's deployed

OpenTofu builds the substrate; ArgoCD reconciles everything in-cluster from this
repo. Tofu installs ArgoCD and a root ApplicationSet that generates one Argo
Application per directory under `platform/` and `apps/`, ordered by sync wave:

| Wave | Component | Role |
|------|-----------|------|
| — (tofu) | project, network + Cloud NAT, Cloud DNS, GKE, KMS + Workload Identity, budget | GCP substrate |
| -2 | cert-manager | TLS (Let's Encrypt + selfsigned issuers) |
| -1 | OpenBao, bank-vaults webhook | secrets store (file backend, GCP KMS auto-unseal) + env injection |
| 0 | external-dns, ingress-nginx, external-secrets, dex, oauth2-proxy | DNS records, ingress, OpenBao→k8s secret bridge, admin SSO |
| 1 | demarkus-broker, demarkus-worlds, backups | the broker + MCP gateway, one Application per world (incl. the `root` hub), CSI snapshot CronJob |
| 2 | demarkus-agent | federation crawler — indexes every world's content-hashes into the `root` hub for cross-world discovery |

**Auth:** broker user login is Google OIDC; admin UIs (ArgoCD, OpenBao) are gated
by [Dex](docs/runbook-dex-sso.md) federating GitHub-org membership.
**CI:** `tofu plan` on PR / `tofu apply` on merge via Workload Identity
Federation, no long-lived keys ([docs/runbook-ci-wif.md](docs/runbook-ci-wif.md)).
**Backups:** daily CSI VolumeSnapshots of stateful PVCs
([docs/runbook-backup-restore.md](docs/runbook-backup-restore.md)).

## Cost

Rough baseline, CAD/month (single zonal cluster, low traffic):

| Item | ~CAD/mo |
|------|---------|
| 3× `e2-medium` nodes (sustained-use discount) | 65–80 |
| 1× LoadBalancer (ingress-nginx) | ~18 |
| Cloud NAT + DNS + KMS + disks + snapshots | 10–15 |
| GKE cluster management fee | ~73, usually offset by the one-free-zonal-cluster tier |

**≈ $95–130/mo** if the free tier covers the management fee. A `200 CAD` budget
alert is wired (`budget_alert_email` in tfvars). Biggest levers: node count/size
and the LoadBalancer. Estimates only — confirm against the
[GCP pricing calculator](https://cloud.google.com/products/calculator) and your
live billing.

## Layout

```
tofu/
  modules/{project,network,dns,gke,argocd-bootstrap,platform-iam,billing-budget}/
  bootstrap/ci/          # WIF + tofu-ci SA for GitHub Actions (applied once, locally)
  envs/prod/             # knowledge.demarkus.io — fill terraform.tfvars (gitignored)
bootstrap/               # argocd-values.yaml + root-appset.yaml (tofu applies post-cluster)
platform/                # cluster prerequisites (Argo-managed)
apps/                    # demarkus-broker, demarkus-worlds, demarkus-agent, backups (Argo-managed)
docs/                    # runbooks + instantiate guide
.github/workflows/       # tofu-plan (PR) + tofu-apply (merge)
```

## Runbooks

- [instantiate.md](docs/instantiate.md) — fork → live, end to end
- [runbook-openbao-seed.md](docs/runbook-openbao-seed.md) — OpenBao init + seed secrets
- [runbook-eso-openbao.md](docs/runbook-eso-openbao.md) — OpenBao → k8s Secret bridge
- [runbook-dex-sso.md](docs/runbook-dex-sso.md) — admin SSO via Dex + GitHub
- [runbook-ci-wif.md](docs/runbook-ci-wif.md) — CI via Workload Identity Federation
- [runbook-backup-restore.md](docs/runbook-backup-restore.md) — backups + restore drill

Master plan: `mark://soul.demarkus.io/plans/knowledge-system-gke-deploy.md`.
