# Shared deployment identity, read from the repo-root deployment.yaml — the
# same file ArgoCD's root ApplicationSet reads. Keeping these values in one
# place means standing up a fork is "edit deployment.yaml", not a find/replace
# across tofu vars AND manifests.
#
# Secret / substrate-only knobs (billing_account, org/folder, budget, project
# display name) stay in gitignored terraform.tfvars — see variables.tf.
locals {
  deployment = yamldecode(file("${path.module}/../../../deployment.yaml"))

  project_id = local.deployment.projectId
  region     = local.deployment.region

  knowledge_storage_worlds = {
    for world in local.deployment.worlds : world.name => {
      bucket    = world.storage.bucket
      world_id  = world.storage.worldID
      read_only = try(world.storage.readOnly, false)
    } if try(world.storage, null) != null
  }

  # Cloud DNS zones are fully-qualified with a trailing dot.
  dns_name = "${local.deployment.domain}."

  # Single zonal cluster: zone is the region's "-a" zone. Override the whole
  # scheme here if you need a different zone.
  zone = "${local.region}-a"
}
