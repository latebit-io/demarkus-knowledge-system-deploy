variable "project_id" {
  description = "GCP project ID to create for the knowledge system."
  type        = string
}

variable "project_name" {
  description = "Display name for the project."
  type        = string
}

variable "billing_account" {
  description = "Billing account ID to associate with the project."
  type        = string
}

variable "org_id" {
  description = "Numeric GCP organization ID. Set this OR folder_id, not both."
  type        = string
  default     = null
}

variable "folder_id" {
  description = "Numeric GCP folder ID. Set this OR org_id, not both."
  type        = string
  default     = null
}

variable "region" {
  description = "Default GCP region for resources in this environment."
  type        = string
  default     = "northamerica-northeast2"
}

variable "dns_name" {
  description = "Fully-qualified DNS name for the Cloud DNS zone, with trailing dot."
  type        = string
  default     = "knowledge.demarkus.io."
}

variable "zone" {
  description = "Single zone for the GKE cluster. Must be in the same region as the subnet."
  type        = string
  default     = "northamerica-northeast2-a"
}

variable "budget_amount" {
  description = "Monthly budget cap in USD. Soft cap — alerts only, doesn't stop spend."
  type        = number
  default     = 200
}

variable "budget_alert_email" {
  description = "Email to receive budget threshold notifications. Required — set in terraform.tfvars."
  type        = string
}
