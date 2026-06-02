# NOTE: project_id, region, dns_name, and zone are NOT variables — they come
# from the repo-root deployment.yaml (the single source of truth shared with
# ArgoCD), via locals.tf. Only secret / substrate-only knobs live here.

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

variable "budget_amount" {
  description = "Monthly budget cap, denominated in `budget_currency`. Soft cap — alerts only, doesn't stop spend."
  type        = number
  default     = 200
}

variable "budget_alert_email" {
  description = "Email to receive budget threshold notifications. Required — set in terraform.tfvars."
  type        = string
}

variable "budget_currency" {
  description = "ISO 4217 currency code for the budget. MUST match the billing account's currency (the API rejects mismatches)."
  type        = string
  default     = "CAD"
}
