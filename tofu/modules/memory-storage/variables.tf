variable "project_id" {
  description = "GCP project the tenant buckets are created in."
  type        = string
}

variable "workload_identity_pool" {
  description = "GKE Workload Identity pool, typically '<project_id>.svc.id.goog'."
  type        = string
}

variable "kubernetes_namespace" {
  description = "Namespace running the memory broker and its knowledge server."
  type        = string
  default     = "demarkus-memory"
}

variable "broker_kubernetes_service_account" {
  description = "Memory-broker Kubernetes service account name."
  type        = string
  default     = "demarkus-memory-broker"
}

variable "server_kubernetes_service_account" {
  description = "Memory knowledge-server Kubernetes service account name."
  type        = string
  default     = "memory"
}

variable "bucket_prefix" {
  description = "Tenant bucket name prefix (gs://<prefix><slug>). Scopes every IAM grant."
  type        = string
}
