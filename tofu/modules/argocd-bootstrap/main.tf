resource "helm_release" "argocd" {
  name       = "argocd"
  namespace  = var.namespace
  repository = "https://argoproj.github.io/argo-helm"
  chart      = "argo-cd"
  version    = var.chart_version

  create_namespace = true
  atomic           = true
  wait             = true
  timeout          = 600

  values = [var.values_yaml]
}

# Split the root ApplicationSet document on `---` boundaries so each manifest
# can be applied separately via the kubectl provider.
locals {
  root_appset_manifests = [
    for doc in split("\n---\n", var.root_appset_yaml) :
    doc if length(trimspace(doc)) > 0
  ]
}

resource "kubectl_manifest" "root_appset" {
  for_each = { for i, doc in local.root_appset_manifests : tostring(i) => doc }

  yaml_body         = each.value
  server_side_apply = true
  wait              = true

  depends_on = [helm_release.argocd]
}
