variable "project_id" {
  description = "The GCP project ID to create (must be globally unique)."
  type        = string
}

variable "project_name" {
  description = "Human-readable display name for the project."
  type        = string
}

variable "billing_account" {
  description = "Billing account ID to associate with the project (e.g. 0X0X0X-0X0X0X-0X0X0X)."
  type        = string
}

variable "org_id" {
  description = "Numeric organization ID. Mutually exclusive with folder_id."
  type        = string
  default     = null
}

variable "folder_id" {
  description = "Numeric folder ID to parent under. Mutually exclusive with org_id."
  type        = string
  default     = null
}

variable "apis" {
  description = "GCP service APIs to enable on the project."
  type        = list(string)
  default = [
    "cloudresourcemanager.googleapis.com",
    "serviceusage.googleapis.com",
    "compute.googleapis.com",
    "container.googleapis.com",
    "dns.googleapis.com",
    "iam.googleapis.com",
    "cloudkms.googleapis.com",
    "billingbudgets.googleapis.com",
  ]
}

variable "auto_create_network" {
  description = "Whether GCP should auto-create the default VPC. We create our own in the network module, so leave this false."
  type        = bool
  default     = false
}
