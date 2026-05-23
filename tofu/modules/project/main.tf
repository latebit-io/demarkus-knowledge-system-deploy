locals {
  has_org    = var.org_id != null
  has_folder = var.folder_id != null
}

# Enforce mutually-exclusive parent: exactly one of org_id or folder_id must be set.
resource "terraform_data" "parent_check" {
  lifecycle {
    precondition {
      condition     = local.has_org != local.has_folder
      error_message = "Exactly one of org_id or folder_id must be set."
    }
  }
}

resource "google_project" "this" {
  name            = var.project_name
  project_id      = var.project_id
  billing_account = var.billing_account

  org_id    = var.org_id
  folder_id = var.folder_id

  auto_create_network = var.auto_create_network

  deletion_policy = "PREVENT"
}

resource "google_project_service" "enabled" {
  for_each = toset(var.apis)

  project = google_project.this.project_id
  service = each.value

  disable_on_destroy         = false
  disable_dependent_services = false
}
