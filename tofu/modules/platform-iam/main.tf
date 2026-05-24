# ─── KMS key for OpenBao auto-unseal ─────────────────────────────────────────

resource "google_kms_key_ring" "platform" {
  project  = var.project_id
  name     = var.kms_key_ring_name
  location = var.region
}

resource "google_kms_crypto_key" "openbao_unseal" {
  name            = var.openbao_unseal_key_name
  key_ring        = google_kms_key_ring.platform.id
  purpose         = "ENCRYPT_DECRYPT"
  rotation_period = var.openbao_unseal_key_rotation_period

  # KMS keys cannot actually be deleted (only their versions). Tofu will
  # destroy the resource from state and orphan the key. Allow that.
  lifecycle {
    prevent_destroy = false
  }
}

# ─── OpenBao auto-unseal GSA + Workload Identity ─────────────────────────────

resource "google_service_account" "openbao_unseal" {
  project      = var.project_id
  account_id   = "openbao-unseal"
  display_name = "OpenBao auto-unseal (Cloud KMS encrypt/decrypt)"
}

resource "google_kms_crypto_key_iam_member" "openbao_unseal" {
  crypto_key_id = google_kms_crypto_key.openbao_unseal.id
  role          = "roles/cloudkms.cryptoKeyEncrypterDecrypter"
  member        = "serviceAccount:${google_service_account.openbao_unseal.email}"
}

resource "google_service_account_iam_member" "openbao_unseal_wi" {
  service_account_id = google_service_account.openbao_unseal.name
  role               = "roles/iam.workloadIdentityUser"
  member             = "serviceAccount:${var.workload_identity_pool}[${var.openbao_namespace}/${var.openbao_ksa}]"
}

# ─── external-dns GSA + Workload Identity ────────────────────────────────────

resource "google_service_account" "external_dns" {
  project      = var.project_id
  account_id   = "external-dns"
  display_name = "external-dns (Cloud DNS record management)"
}

# Zone-scoped IAM (not project-scoped) — least privilege.
resource "google_dns_managed_zone_iam_member" "external_dns" {
  project      = var.project_id
  managed_zone = var.dns_zone_name
  role         = "roles/dns.admin"
  member       = "serviceAccount:${google_service_account.external_dns.email}"
}

resource "google_service_account_iam_member" "external_dns_wi" {
  service_account_id = google_service_account.external_dns.name
  role               = "roles/iam.workloadIdentityUser"
  member             = "serviceAccount:${var.workload_identity_pool}[${var.external_dns_namespace}/${var.external_dns_ksa}]"
}
