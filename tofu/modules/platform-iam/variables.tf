variable "project_id" {
  description = "GCP project."
  type        = string
}

variable "region" {
  description = "Region for the KMS key ring."
  type        = string
}

variable "dns_zone_name" {
  description = "Cloud DNS managed zone name that external-dns is allowed to write to."
  type        = string
}

variable "workload_identity_pool" {
  description = "Workload Identity pool, typically '<project_id>.svc.id.goog'."
  type        = string
}

variable "openbao_namespace" {
  description = "Kubernetes namespace OpenBao runs in."
  type        = string
  default     = "openbao"
}

variable "openbao_ksa" {
  description = "Kubernetes service account name OpenBao runs as."
  type        = string
  default     = "openbao"
}

variable "external_dns_namespace" {
  description = "Kubernetes namespace external-dns runs in."
  type        = string
  default     = "external-dns"
}

variable "external_dns_ksa" {
  description = "Kubernetes service account name external-dns runs as."
  type        = string
  default     = "external-dns"
}

variable "kms_key_ring_name" {
  description = "Name of the KMS key ring."
  type        = string
  default     = "demarkus-platform"
}

variable "openbao_unseal_key_name" {
  description = "Name of the KMS key used for OpenBao auto-unseal."
  type        = string
  default     = "openbao-unseal"
}

variable "openbao_unseal_key_rotation_period" {
  description = "Rotation period for the unseal key (Google duration string). Auto-unseal supports key rotation transparently."
  type        = string
  default     = "7776000s" # 90 days
}
