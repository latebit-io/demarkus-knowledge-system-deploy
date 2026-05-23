module "project" {
  source = "../../modules/project"

  project_id      = var.project_id
  project_name    = var.project_name
  billing_account = var.billing_account
  org_id          = var.org_id
  folder_id       = var.folder_id
}
