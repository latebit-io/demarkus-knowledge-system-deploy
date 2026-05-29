# Values to wire into GitHub Actions (repo Settings → Secrets and variables →
# Actions). See docs/runbook-ci-wif.md.

output "workload_identity_provider" {
  description = "Set as the WIF_PROVIDER Actions variable; passed to google-github-actions/auth as workload_identity_provider."
  value       = google_iam_workload_identity_pool_provider.github.name
}

output "tofu_ci_service_account_email" {
  description = "Set as the WIF_SERVICE_ACCOUNT Actions variable; passed to google-github-actions/auth as service_account."
  value       = google_service_account.tofu_ci.email
}
