output "project_id" {
  description = "The created project's ID."
  value       = google_project.this.project_id
}

output "project_number" {
  description = "The created project's numeric ID."
  value       = google_project.this.number
}

output "enabled_apis" {
  description = "The set of APIs enabled on the project."
  value       = sort([for s in google_project_service.enabled : s.service])
}
