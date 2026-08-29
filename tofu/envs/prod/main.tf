module "project" {
  source = "../../modules/project"

  project_id      = local.project_id
  project_name    = var.project_name
  billing_account = var.billing_account
  org_id          = var.org_id
  folder_id       = var.folder_id
}

module "network" {
  source = "../../modules/network"

  project_id = module.project.project_id
  region     = local.region
}

module "dns" {
  source = "../../modules/dns"

  project_id = module.project.project_id
  dns_name   = local.dns_name
}

module "gke" {
  source = "../../modules/gke"

  project_id          = module.project.project_id
  zone                = local.zone
  vpc_self_link       = module.network.vpc_id
  subnet_self_link    = module.network.subnet_id
  pods_range_name     = module.network.pods_range_name
  services_range_name = module.network.services_range_name

  # Dynamic ISP IP makes CIDR pinning impractical; kubeconfig + RBAC still
  # required to do anything against the control plane.
  authorized_networks = [{
    cidr_block   = "0.0.0.0/0"
    display_name = "open"
  }]
}

module "argocd_bootstrap" {
  source = "../../modules/argocd-bootstrap"

  values_yaml      = file("${path.module}/../../../bootstrap/argocd-values.yaml")
  root_appset_yaml = file("${path.module}/../../../bootstrap/root-appset.yaml")

  # The helm + kubectl providers are wired in providers.tf; this module just
  # consumes them. depends_on ensures the cluster + node pool exist before
  # we try to install anything.
  depends_on = [module.gke]
}

module "platform_iam" {
  source = "../../modules/platform-iam"

  project_id             = module.project.project_id
  region                 = local.region
  dns_zone_name          = module.dns.zone_name
  workload_identity_pool = module.gke.workload_identity_pool
}

module "knowledge_storage" {
  source = "../../modules/knowledge-storage"

  project_id                 = module.project.project_id
  region                     = local.region
  workload_identity_pool     = module.gke.workload_identity_pool
  kubernetes_namespace       = "demarkus-knowledge"
  kubernetes_service_account = "knowledge"
  worlds                     = local.knowledge_storage_worlds

  depends_on = [module.project]
}

module "dns_memory" {
  source = "../../modules/dns"

  project_id  = module.project.project_id
  zone_name   = "demarkus-memory"
  dns_name    = local.memory_dns_name
  description = "Demarkus memory service — managed by OpenTofu"
}

# external-dns manages records in the memory zone too (its project-level
# dns.reader from platform-iam already lets it discover the zone).
resource "google_dns_managed_zone_iam_member" "external_dns_memory" {
  project      = module.project.project_id
  managed_zone = module.dns_memory.zone_name
  role         = "roles/dns.admin"
  member       = "serviceAccount:${module.platform_iam.external_dns_gsa_email}"
}

module "memory_storage" {
  source = "../../modules/memory-storage"

  project_id             = module.project.project_id
  workload_identity_pool = module.gke.workload_identity_pool
  bucket_prefix          = "${local.project_id}-memory-"

  depends_on = [module.project]
}

module "billing_budget" {
  source = "../../modules/billing-budget"

  project_id      = module.project.project_id
  project_number  = module.project.project_number
  billing_account = var.billing_account
  alert_email     = var.budget_alert_email
  amount          = var.budget_amount
  currency_code   = var.budget_currency
}
