output "kms_key_ring_id" {
  description = "Full resource ID of the KMS key ring."
  value       = google_kms_key_ring.platform.id
}

output "openbao_unseal_key_id" {
  description = "Full resource ID of the OpenBao unseal key (projects/.../locations/.../keyRings/.../cryptoKeys/...)."
  value       = google_kms_crypto_key.openbao_unseal.id
}

output "openbao_unseal_key_self_link" {
  description = "Short path form of the unseal key for OpenBao seal config (key_ring + crypto_key)."
  value = {
    project    = var.project_id
    region     = var.region
    key_ring   = google_kms_key_ring.platform.name
    crypto_key = google_kms_crypto_key.openbao_unseal.name
  }
}

output "openbao_gsa_email" {
  description = "Google SA email to put on the openbao KSA's iam.gke.io/gcp-service-account annotation."
  value       = google_service_account.openbao_unseal.email
}

output "external_dns_gsa_email" {
  description = "Google SA email to put on the external-dns KSA's iam.gke.io/gcp-service-account annotation."
  value       = google_service_account.external_dns.email
}
