output "namespace" {
  description = "Namespace ArgoCD was installed into."
  value       = var.namespace
}

output "chart_version" {
  description = "Installed argo-cd chart version."
  value       = helm_release.argocd.version
}

output "port_forward_command" {
  description = "Run this to reach the ArgoCD UI locally before ingress (Phase 5) is wired."
  value       = "kubectl -n ${var.namespace} port-forward svc/argocd-server 8080:80"
}

output "initial_password_command" {
  description = "Run this to read the auto-generated initial admin password."
  value       = "kubectl -n ${var.namespace} get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d; echo"
}
