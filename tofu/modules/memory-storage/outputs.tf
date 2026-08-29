output "broker_gsa_email" {
  description = "Memory-broker Google service account email (KSA annotation)."
  value       = google_service_account.memory_broker.email
}

output "server_gsa_email" {
  description = "Memory knowledge-server Google service account email (KSA annotation)."
  value       = google_service_account.memory_server.email
}
