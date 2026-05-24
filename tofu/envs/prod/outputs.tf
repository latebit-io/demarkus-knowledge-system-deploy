output "project_id" {
  description = "GCP project ID."
  value       = module.project.project_id
}

output "vpc_name" {
  description = "Name of the VPC."
  value       = module.network.vpc_name
}

output "subnet_name" {
  description = "Name of the regional subnet."
  value       = module.network.subnet_name
}

output "dns_zone_name" {
  description = "Cloud DNS managed zone name."
  value       = module.dns.zone_name
}

output "dns_name_servers" {
  description = "Authoritative name servers for the zone. Add as NS records at the parent (Cloudflare) for delegation."
  value       = module.dns.name_servers
}

output "dns_ds_records" {
  description = "DS records to add at the parent zone for DNSSEC chain of trust."
  value       = module.dns.ds_records
}

output "cluster_name" {
  description = "GKE cluster name."
  value       = module.gke.cluster_name
}

output "cluster_location" {
  description = "Zone of the GKE cluster."
  value       = module.gke.cluster_location
}

output "get_credentials_command" {
  description = "Run this to populate kubeconfig for the new cluster."
  value       = "gcloud container clusters get-credentials ${module.gke.cluster_name} --zone=${module.gke.cluster_location} --project=${module.project.project_id}"
}
