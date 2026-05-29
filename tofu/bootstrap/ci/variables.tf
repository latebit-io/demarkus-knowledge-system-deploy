variable "bootstrap_project_id" {
  description = "Project that holds the CI identity infra (WIF pool + tofu-ci SA). Separate from the prod project so a `tofu destroy` on prod can't remove the identity CI uses to manage it. Holds the tofu state bucket too."
  type        = string
  default     = "latebit-tofu-bootstrap"
}

variable "prod_project_id" {
  description = "The tofu-managed prod project the CI service account is granted to manage. Set in terraform.tfvars (gitignored)."
  type        = string
}

variable "billing_account" {
  description = "Billing account ID. The CI SA needs billing-account-level roles because the budget resource (google_billing_budget) lives there, not on the project. Set in terraform.tfvars (gitignored)."
  type        = string
}

variable "github_repo" {
  description = "owner/repo allowed to mint WIF tokens for the tofu-ci SA. Pins the provider attribute_condition AND the workloadIdentityUser principalSet."
  type        = string
  default     = "latebit-io/demarkus-knowledge-system-deploy"
}

variable "state_bucket" {
  description = "GCS bucket holding tofu state. CI SA gets objectAdmin on it (read/write/lock state). Non-sensitive, already public in backend.tf."
  type        = string
  default     = "latebit-knowledge-tofu-state"
}

variable "region" {
  description = "Default region for the google provider in this root."
  type        = string
  default     = "northamerica-northeast2"
}
