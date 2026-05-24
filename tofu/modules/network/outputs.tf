output "vpc_id" {
  description = "Self-link of the VPC."
  value       = google_compute_network.vpc.self_link
}

output "vpc_name" {
  description = "Name of the VPC."
  value       = google_compute_network.vpc.name
}

output "subnet_id" {
  description = "Self-link of the regional subnet."
  value       = google_compute_subnetwork.nodes.self_link
}

output "subnet_name" {
  description = "Name of the regional subnet."
  value       = google_compute_subnetwork.nodes.name
}

output "pods_range_name" {
  description = "Name of the pods secondary range (pass to GKE)."
  value       = var.pods_range_name
}

output "services_range_name" {
  description = "Name of the services secondary range (pass to GKE)."
  value       = var.services_range_name
}
