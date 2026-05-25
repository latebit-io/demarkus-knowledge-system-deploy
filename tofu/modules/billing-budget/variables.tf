variable "project_id" {
  description = "Project to attach the notification channel to (and the project this budget tracks)."
  type        = string
}

variable "project_number" {
  description = "Numeric project ID, required by the budget filter (projects/<NUMBER> format)."
  type        = string
}

variable "billing_account" {
  description = "Billing account ID the project is associated with."
  type        = string
}

variable "display_name" {
  description = "Display name for the budget in the GCP console."
  type        = string
  default     = "knowledge-system monthly cap"
}

variable "amount" {
  description = "Monthly budget amount (whole currency units, no decimals)."
  type        = number
  default     = 200

  validation {
    condition     = var.amount > 0 && floor(var.amount) == var.amount
    error_message = "amount must be a positive whole number — the Cloud Billing Budget API's specified_amount.units only accepts whole currency units (fractions would need to go through .nanos, which this module doesn't expose)."
  }
}

variable "currency_code" {
  description = "ISO 4217 currency code. Must match the billing account's currency."
  type        = string
  default     = "USD"
}

variable "alert_email" {
  description = "Email address to notify when budget thresholds are crossed."
  type        = string
}

variable "thresholds" {
  description = "Fractional thresholds (0.5 = 50% of budget) to fire alerts at."
  type        = list(number)
  default     = [0.5, 0.8, 1.0, 1.2]
}
