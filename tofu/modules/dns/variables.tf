variable "project_id" {
  description = "GCP project to create the managed zone in."
  type        = string
}

variable "zone_name" {
  description = "Cloud DNS managed zone name (no dots; used as the resource identifier in GCP)."
  type        = string
  default     = "demarkus-knowledge"
}

variable "dns_name" {
  description = "Fully-qualified DNS name for the zone, with trailing dot (e.g. knowledge.demarkus.io.)."
  type        = string

  validation {
    condition     = can(regex("\\.$", var.dns_name))
    error_message = "dns_name must end with a trailing dot (e.g. knowledge.demarkus.io.)."
  }
}

variable "dnssec_enabled" {
  description = "Whether to enable DNSSEC on the zone. Requires a corresponding DS record at the parent zone."
  type        = bool
  default     = true
}

variable "description" {
  description = "Human-readable description of the zone."
  type        = string
  default     = "Demarkus knowledge system — managed by OpenTofu"
}
