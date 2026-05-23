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
  default     = "us-central1"
}
