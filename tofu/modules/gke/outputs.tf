output "cluster_name" {
  description = "GKE cluster name."
  value       = google_container_cluster.this.name
}

output "cluster_location" {
  description = "Zone (or region) the cluster lives in."
  value       = google_container_cluster.this.location
}

output "cluster_endpoint" {
  description = "Control-plane endpoint URL."
  value       = google_container_cluster.this.endpoint
  sensitive   = true
}

output "cluster_ca_certificate" {
  description = "Base64-encoded cluster CA certificate (for kubeconfig)."
  value       = google_container_cluster.this.master_auth[0].cluster_ca_certificate
  sensitive   = true
}

output "workload_identity_pool" {
  description = "Workload Identity pool, used when binding KSAs to GSAs."
  value       = "${var.project_id}.svc.id.goog"
}

output "node_service_account_email" {
  description = "Email of the SA the node pool runs as."
  value       = google_service_account.nodes.email
}
