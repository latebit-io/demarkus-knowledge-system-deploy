variable "project_id" {
  description = "GCP project."
  type        = string
}

variable "dns_zone_name" {
  description = "Cloud DNS managed zone name that external-dns is allowed to write to."
  type        = string
}

variable "workload_identity_pool" {
  description = "Workload Identity pool, typically '<project_id>.svc.id.goog'."
  type        = string
}

variable "external_dns_namespace" {
  description = "Kubernetes namespace external-dns runs in."
  type        = string
  default     = "external-dns"
}

variable "external_dns_ksa" {
  description = "Kubernetes service account name external-dns runs as."
  type        = string
  default     = "external-dns"
}

variable "external_secrets_namespace" {
  description = "Kubernetes namespace the External Secrets Operator runs in."
  type        = string
  default     = "external-secrets"
}

variable "external_secrets_ksa" {
  description = "Kubernetes service account name the External Secrets controller runs as."
  type        = string
  default     = "external-secrets"
}

variable "secret_manager_secrets" {
  description = "Secret Manager secret IDs ESO may read. Containers only; values are added out of band so they never enter tofu state."
  type        = set(string)
  default = [
    "broker-oidc-client",
    "broker-jwks-signing-key",
    "broker-memory-jwks-signing-key",
    "dex-argocd-client",
    "dex-github-client",
    "library-llm",
    "library-oauth-client",
    "oauth2-proxy-github-client",
  ]
}
