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
