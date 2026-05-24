variable "project_id" {
  description = "GCP project to create the cluster in."
  type        = string
}

variable "cluster_name" {
  description = "Cluster name."
  type        = string
  default     = "demarkus"
}

variable "zone" {
  description = "Single zone for the cluster (zonal = free tier eligible). Must be in the same region as the subnet."
  type        = string
}

variable "vpc_self_link" {
  description = "Self-link of the VPC from the network module."
  type        = string
}

variable "subnet_self_link" {
  description = "Self-link of the subnet from the network module."
  type        = string
}

variable "pods_range_name" {
  description = "Name of the pods secondary range on the subnet."
  type        = string
}

variable "services_range_name" {
  description = "Name of the services secondary range on the subnet."
  type        = string
}

variable "master_ipv4_cidr" {
  description = "RFC1918 /28 for the control-plane VPC peering. Must not overlap with the subnet or its secondary ranges."
  type        = string
  default     = "172.16.0.0/28"
}

variable "authorized_networks" {
  description = "CIDR blocks allowed to reach the public control-plane endpoint. Defaults to empty (fail closed) — callers must explicitly opt in."
  type = list(object({
    cidr_block   = string
    display_name = string
  }))
  default = []
}

variable "release_channel" {
  description = "GKE release channel: RAPID, REGULAR, STABLE, or UNSPECIFIED (for version pinning)."
  type        = string
  default     = "REGULAR"
}

variable "node_count" {
  description = "Fixed number of nodes in the pool (no autoscaling)."
  type        = number
  default     = 3
}

variable "machine_type" {
  description = "GCE machine type for worker nodes."
  type        = string
  default     = "e2-medium"
}

variable "disk_size_gb" {
  description = "Boot disk size per node."
  type        = number
  default     = 50
}

variable "disk_type" {
  description = "Boot disk type. pd-standard is cheapest; pd-balanced is faster."
  type        = string
  default     = "pd-standard"
}

variable "deletion_protection" {
  description = "GKE deletion protection. Leave false while iterating; flip on before going live."
  type        = bool
  default     = false
}
