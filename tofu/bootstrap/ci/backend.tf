terraform {
  backend "gcs" {
    bucket = "latebit-knowledge-tofu-state"
    prefix = "knowledge-system/ci-bootstrap"
  }
}
