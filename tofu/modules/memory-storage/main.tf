# Memory-as-a-service storage IAM. Tenant buckets are created DYNAMICALLY
# by the memory broker (bucket-per-tenant, gs://<prefix><slug>), so unlike
# knowledge-storage there are no static bucket resources here — only the
# two service accounts and prefix-scoped project IAM that lets the broker
# create/delete tenant buckets and the memory knowledge server serve them.

resource "google_service_account" "memory_broker" {
  project      = var.project_id
  account_id   = "demarkus-memory-broker"
  display_name = "Demarkus memory broker (tenant bucket lifecycle)"
}

resource "google_service_account" "memory_server" {
  project      = var.project_id
  account_id   = "demarkus-memory-server"
  display_name = "Demarkus memory knowledge server (tenant world storage)"
}

# Broker: full bucket lifecycle (create, lockdown-verify, soft-delete
# disable, purge, delete), conditioned to the tenant prefix so it can
# never touch knowledge-system or platform buckets.
resource "google_project_iam_member" "memory_broker_storage" {
  project = var.project_id
  role    = "roles/storage.admin"
  member  = "serviceAccount:${google_service_account.memory_broker.email}"

  condition {
    title       = "memory-tenant-buckets-only"
    description = "Restrict to dynamically provisioned tenant buckets."
    expression  = "resource.name.startsWith(\"projects/_/buckets/${var.bucket_prefix}\")"
  }
}

# Server: object read/write on tenant buckets only. objectUser also covers
# the bucket metadata reads the GCS bucketstore backend performs.
resource "google_project_iam_member" "memory_server_storage" {
  project = var.project_id
  role    = "roles/storage.objectUser"
  member  = "serviceAccount:${google_service_account.memory_server.email}"

  condition {
    title       = "memory-tenant-buckets-only"
    description = "Restrict to dynamically provisioned tenant buckets."
    expression  = "resource.name.startsWith(\"projects/_/buckets/${var.bucket_prefix}\")"
  }
}

resource "google_service_account_iam_member" "memory_broker_wi" {
  service_account_id = google_service_account.memory_broker.name
  role               = "roles/iam.workloadIdentityUser"
  member             = "serviceAccount:${var.workload_identity_pool}[${var.kubernetes_namespace}/${var.broker_kubernetes_service_account}]"

  lifecycle {
    create_before_destroy = true
  }
}

resource "google_service_account_iam_member" "memory_server_wi" {
  service_account_id = google_service_account.memory_server.name
  role               = "roles/iam.workloadIdentityUser"
  member             = "serviceAccount:${var.workload_identity_pool}[${var.kubernetes_namespace}/${var.server_kubernetes_service_account}]"

  lifecycle {
    create_before_destroy = true
  }
}
