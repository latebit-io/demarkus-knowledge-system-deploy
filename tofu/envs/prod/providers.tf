provider "google" {
  project = local.project_id
  region  = local.region

  # Some GCP APIs (notably billingbudgets) bill API quota to the caller's
  # project rather than the resource's. Without these two settings the
  # provider falls back to a stray default project (often the gcloud SDK's
  # internal one), and the call fails with SERVICE_DISABLED even though
  # the API IS enabled on the project. Setting both makes every request
  # explicit about which project foots the API quota.
  user_project_override = true
  billing_project       = local.project_id
}

# Short-lived access token for the currently-authenticated gcloud user (local)
# or the WIF-impersonated SA (CI). Used by helm and kubectl providers to talk
# to the GKE control plane.
data "google_client_config" "this" {}

provider "helm" {
  kubernetes {
    host                   = "https://${module.gke.cluster_endpoint}"
    cluster_ca_certificate = base64decode(module.gke.cluster_ca_certificate)
    token                  = data.google_client_config.this.access_token
  }
}

provider "kubectl" {
  host                   = "https://${module.gke.cluster_endpoint}"
  cluster_ca_certificate = base64decode(module.gke.cluster_ca_certificate)
  token                  = data.google_client_config.this.access_token
  load_config_file       = false
}
