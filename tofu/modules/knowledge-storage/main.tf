resource "google_storage_bucket" "world" {
  for_each = var.worlds

  project                     = var.project_id
  name                        = each.value.bucket
  location                    = var.region
  storage_class               = "STANDARD"
  uniform_bucket_level_access = true
  public_access_prevention    = "enforced"
  force_destroy               = false

  soft_delete_policy {
    retention_duration_seconds = 604800
  }

  lifecycle {
    prevent_destroy = true
  }
}

resource "google_service_account" "knowledge_server" {
  project      = var.project_id
  account_id   = "demarkus-knowledge-server"
  display_name = "Demarkus knowledge server"
}

resource "google_storage_bucket_iam_member" "knowledge_server" {
  for_each = google_storage_bucket.world

  bucket = each.value.name
  role   = var.worlds[each.key].read_only ? "roles/storage.objectViewer" : "roles/storage.objectUser"
  member = "serviceAccount:${google_service_account.knowledge_server.email}"

  lifecycle {
    create_before_destroy = true
  }
}

resource "google_service_account_iam_member" "knowledge_server_wi" {
  service_account_id = google_service_account.knowledge_server.name
  role               = "roles/iam.workloadIdentityUser"
  member             = "serviceAccount:${var.workload_identity_pool}[${var.kubernetes_namespace}/${var.kubernetes_service_account}]"

  lifecycle {
    create_before_destroy = true
  }
}
