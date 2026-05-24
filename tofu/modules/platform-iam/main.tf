# ─── KMS key for OpenBao auto-unseal ─────────────────────────────────────────

resource "google_kms_key_ring" "platform" {
  project  = var.project_id
  name     = var.kms_key_ring_name
  location = var.region

  # Locking the key ring locks the keys it contains. To actually tear this
  # down, remove the lifecycle block first.
  lifecycle {
    prevent_destroy = true
  }
}

resource "google_kms_crypto_key" "openbao_unseal" {
  name            = var.openbao_unseal_key_name
  key_ring        = google_kms_key_ring.platform.id
  purpose         = "ENCRYPT_DECRYPT"
  rotation_period = var.openbao_unseal_key_rotation_period

  # Losing this key = OpenBao becomes permanently unsealable = total data
  # loss for everything OpenBao has ever encrypted.
  lifecycle {
    prevent_destroy = true
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

# external-dns needs LIST permission on managed zones at the project level
# to discover which zone matches its domain filter. roles/dns.reader is
# read-only (managedZones.list/get + resourceRecordSets.list) and doesn't
# allow modifying anything.
resource "google_project_iam_member" "external_dns_reader" {
  project = var.project_id
  role    = "roles/dns.reader"
  member  = "serviceAccount:${google_service_account.external_dns.email}"
}

# Write access scoped to the specific managed zone only — even with reader
# at the project level, the GSA can only modify records in this zone.
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
