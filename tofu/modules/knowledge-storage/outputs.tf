output "bucket_names" {
  description = "Bucket name by world."
  value       = { for name, bucket in google_storage_bucket.world : name => bucket.name }
}

output "world_ids" {
  description = "Immutable world ID by world."
  value       = { for name, world in var.worlds : name => world.world_id }
}

output "service_account_email" {
  description = "Knowledge-server Google service account email."
  value       = google_service_account.knowledge_server.email
}
