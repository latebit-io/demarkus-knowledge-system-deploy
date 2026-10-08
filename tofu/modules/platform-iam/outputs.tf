output "kms_key_ring_id" {
  description = "Full resource ID of the KMS key ring."
  value       = google_kms_key_ring.platform.id
}

output "external_secrets_gsa_email" {
  description = "Google SA email to put on the external-secrets KSA's iam.gke.io/gcp-service-account annotation."
  value       = google_service_account.external_secrets.email
}

output "external_dns_gsa_email" {
  description = "Google SA email to put on the external-dns KSA's iam.gke.io/gcp-service-account annotation."
  value       = google_service_account.external_dns.email
}
