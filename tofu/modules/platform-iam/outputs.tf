output "external_secrets_gsa_email" {
  description = "Google SA email to put on the external-secrets KSA's iam.gke.io/gcp-service-account annotation."
  value       = google_service_account.external_secrets.email
}

output "external_dns_gsa_email" {
  description = "Google SA email to put on the external-dns KSA's iam.gke.io/gcp-service-account annotation."
  value       = google_service_account.external_dns.email
}
