# ─── Workload Identity Federation: GitHub Actions → tofu-ci SA ────────────────
#
# Phase 8 CI authenticates to GCP with short-lived WIF-federated tokens, never
# long-lived JSON service-account keys. These resources live in the bootstrap
# project (outside the prod blast radius) and are applied ONCE locally with
# owner creds; every workflow run thereafter impersonates the SA via OIDC.

# The WIF exchange impersonates tofu_ci via the IAM Service Account Credentials
# API, which must be enabled in the project that HOSTS the SA. Without this, CI
# init fails with SERVICE_DISABLED (the local apply doesn't hit it — it uses
# the operator's own creds, not the token exchange).
resource "google_project_service" "iamcredentials" {
  project = var.bootstrap_project_id
  service = "iamcredentials.googleapis.com"

  disable_on_destroy         = false
  disable_dependent_services = false
}

resource "google_iam_workload_identity_pool" "github" {
  project                   = var.bootstrap_project_id
  workload_identity_pool_id = "github-actions"
  display_name              = "GitHub Actions"
  description               = "WIF pool for GitHub Actions OIDC (Phase 8 CI)"
}

resource "google_iam_workload_identity_pool_provider" "github" {
  project                            = var.bootstrap_project_id
  workload_identity_pool_id          = google_iam_workload_identity_pool.github.workload_identity_pool_id
  workload_identity_pool_provider_id = "github"
  display_name                       = "GitHub Actions OIDC"

  attribute_mapping = {
    "google.subject"       = "assertion.sub"
    "attribute.repository" = "assertion.repository"
    "attribute.ref"        = "assertion.ref"
  }

  # Hard scope: only OIDC tokens from this repo are accepted. Without an
  # attribute_condition the provider would trust ANY GitHub repo's token,
  # which combined with the principalSet below would be a takeover path.
  attribute_condition = "assertion.repository == \"${var.github_repo}\""

  oidc {
    issuer_uri = "https://token.actions.githubusercontent.com"
  }
}

resource "google_service_account" "tofu_ci" {
  project      = var.bootstrap_project_id
  account_id   = "tofu-ci"
  display_name = "OpenTofu CI (GitHub Actions via WIF)"
}

# Only workflow runs from var.github_repo may impersonate the SA. Scoped to
# the repository attribute, not a specific branch — branch gating (plan on PR,
# apply on push to main) is enforced by the workflow triggers, not here.
resource "google_service_account_iam_member" "tofu_ci_wif" {
  service_account_id = google_service_account.tofu_ci.name
  role               = "roles/iam.workloadIdentityUser"
  member             = "principalSet://iam.googleapis.com/${google_iam_workload_identity_pool.github.name}/attribute.repository/${var.github_repo}"
}

# ─── Grants the CI SA needs to plan + apply the prod env ──────────────────────

# State backend: read/write/lock the tofu state object. Scoped to the bucket.
resource "google_storage_bucket_iam_member" "tofu_ci_state" {
  bucket = var.state_bucket
  role   = "roles/storage.objectAdmin"
  member = "serviceAccount:${google_service_account.tofu_ci.email}"
}

# Bucket lifecycle and IAM only; object access remains scoped to the state
# bucket above and the runtime service account in the production root.
resource "google_project_iam_custom_role" "tofu_ci_knowledge_storage" {
  project     = var.prod_project_id
  role_id     = "tofuCiKnowledgeStorage"
  title       = "OpenTofu CI knowledge storage"
  description = "Manage knowledge-world buckets and their IAM policies"
  permissions = [
    "storage.buckets.create",
    "storage.buckets.get",
    "storage.buckets.getIamPolicy",
    "storage.buckets.setIamPolicy",
    "storage.buckets.update",
  ]
}

resource "google_project_iam_member" "tofu_ci_knowledge_storage" {
  project = var.prod_project_id
  role    = google_project_iam_custom_role.tofu_ci_knowledge_storage.id
  member  = "serviceAccount:${google_service_account.tofu_ci.email}"

  condition {
    title       = "knowledge-world-buckets-only"
    description = "Restrict CI to the deployment's knowledge-world bucket prefix"
    expression  = "resource.type == \"storage.googleapis.com/Bucket\" && resource.name.startsWith(\"projects/_/buckets/${var.prod_project_id}-demarkus-\")"
  }

  lifecycle {
    create_before_destroy = true
  }
}

# Prod roles map to managed modules; owner/editor remain intentionally absent.
resource "google_project_iam_member" "tofu_ci_prod" {
  for_each = toset([
    "roles/compute.networkAdmin",
    "roles/container.admin",
    "roles/dns.admin",
    "roles/serviceusage.serviceUsageAdmin",
    "roles/iam.serviceAccountAdmin",
    "roles/resourcemanager.projectIamAdmin",
    "roles/iam.serviceAccountUser",
    "roles/cloudkms.admin",
    "roles/monitoring.notificationChannelEditor",
  ])

  project = var.prod_project_id
  role    = each.value
  member  = "serviceAccount:${google_service_account.tofu_ci.email}"
}

# Billing account: budgets (google_billing_budget in modules/billing-budget)
# live at the billing-account level, not the project. billing.user lets tofu
# read the project↔billing association; costsManager lets it manage budgets.
# This is the only grant outside the two projects.
resource "google_billing_account_iam_member" "tofu_ci_billing" {
  for_each = toset([
    "roles/billing.user",
    "roles/billing.costsManager",
  ])

  billing_account_id = var.billing_account
  role               = each.value
  member             = "serviceAccount:${google_service_account.tofu_ci.email}"
}
