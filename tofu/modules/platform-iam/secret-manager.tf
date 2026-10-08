# ─── External Secrets Operator -> Secret Manager ─────────────────────────────

resource "google_service_account" "external_secrets" {
  project      = var.project_id
  account_id   = "external-secrets"
  display_name = "External Secrets Operator (Secret Manager read)"
}

resource "google_service_account_iam_member" "external_secrets_wi" {
  service_account_id = google_service_account.external_secrets.name
  role               = "roles/iam.workloadIdentityUser"
  member             = "serviceAccount:${var.workload_identity_pool}[${var.external_secrets_namespace}/${var.external_secrets_ksa}]"
}

# Containers only: values are added with `gcloud secrets versions add` so they
# never land in tofu state.
resource "google_secret_manager_secret" "this" {
  for_each = var.secret_manager_secrets

  project   = var.project_id
  secret_id = each.value

  replication {
    auto {}
  }
}

# Per-secret access, not project-wide, so ESO can only read what is listed.
resource "google_secret_manager_secret_iam_member" "external_secrets" {
  for_each = google_secret_manager_secret.this

  project   = var.project_id
  secret_id = each.value.secret_id
  role      = "roles/secretmanager.secretAccessor"
  member    = "serviceAccount:${google_service_account.external_secrets.email}"
}
