variable "project_id" {
  description = "GCP project containing the buckets and service account."
  type        = string
}

variable "region" {
  description = "GCP region for every world bucket."
  type        = string
}

variable "workload_identity_pool" {
  description = "GKE Workload Identity pool, typically '<project_id>.svc.id.goog'."
  type        = string
}

variable "kubernetes_namespace" {
  description = "Namespace containing the knowledge-server Kubernetes service account."
  type        = string
}

variable "kubernetes_service_account" {
  description = "Knowledge-server Kubernetes service account name."
  type        = string
}

variable "worlds" {
  description = "Storage configuration keyed by world name."
  type = map(object({
    bucket    = string
    world_id  = string
    read_only = optional(bool, false)
  }))
}
