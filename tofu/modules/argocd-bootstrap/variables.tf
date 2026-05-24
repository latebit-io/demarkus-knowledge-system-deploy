variable "namespace" {
  description = "Namespace to install ArgoCD into."
  type        = string
  default     = "argocd"
}

variable "chart_version" {
  description = "argo-cd helm chart version."
  type        = string
  default     = "7.7.10"
}

variable "values_yaml" {
  description = "ArgoCD chart values (full YAML document body)."
  type        = string
}

variable "root_appset_yaml" {
  description = "Root ApplicationSet YAML (one or more manifests separated by `---`)."
  type        = string
}
