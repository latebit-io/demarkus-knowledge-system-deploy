provider "google" {
  project = var.project_id
  region  = var.region
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
