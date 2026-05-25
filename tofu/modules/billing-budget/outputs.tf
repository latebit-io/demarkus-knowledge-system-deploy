output "budget_name" {
  description = "Resource name of the budget."
  value       = google_billing_budget.this.name
}

output "notification_channel_id" {
  description = "ID of the email notification channel used by the budget."
  value       = google_monitoring_notification_channel.email.id
}
