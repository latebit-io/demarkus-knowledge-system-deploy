variable "project_id" {
  description = "GCP project to create the VPC in."
  type        = string
}

variable "region" {
  description = "Region for the subnet and Cloud NAT."
  type        = string
}

variable "network_name" {
  description = "Name of the VPC."
  type        = string
  default     = "demarkus-net"
}

variable "subnet_name" {
  description = "Name of the regional subnet."
  type        = string
  default     = "demarkus-subnet"
}

variable "nodes_cidr" {
  description = "Primary CIDR for the subnet (GKE node IPs)."
  type        = string
  default     = "10.10.0.0/20"
}

variable "pods_cidr" {
  description = "Secondary CIDR for GKE pods (alias IP range)."
  type        = string
  default     = "10.20.0.0/16"
}

variable "services_cidr" {
  description = "Secondary CIDR for GKE services (alias IP range)."
  type        = string
  default     = "10.30.0.0/22"
}

variable "pods_range_name" {
  description = "Name of the pods secondary range, referenced by the GKE module."
  type        = string
  default     = "pods"
}

variable "services_range_name" {
  description = "Name of the services secondary range, referenced by the GKE module."
  type        = string
  default     = "services"
}
