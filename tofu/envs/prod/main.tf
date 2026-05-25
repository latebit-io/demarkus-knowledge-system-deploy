module "project" {
  source = "../../modules/project"

  project_id      = var.project_id
  project_name    = var.project_name
  billing_account = var.billing_account
  org_id          = var.org_id
  folder_id       = var.folder_id
}

module "network" {
  source = "../../modules/network"

  project_id = module.project.project_id
  region     = var.region
}

module "dns" {
  source = "../../modules/dns"

  project_id = module.project.project_id
  dns_name   = var.dns_name
}

module "gke" {
  source = "../../modules/gke"

  project_id          = module.project.project_id
  zone                = var.zone
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
  region                 = var.region
  dns_zone_name          = module.dns.zone_name
  workload_identity_pool = module.gke.workload_identity_pool
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
