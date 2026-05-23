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
