resource "google_dns_managed_zone" "this" {
  project     = var.project_id
  name        = var.zone_name
  dns_name    = var.dns_name
  description = var.description

  dnssec_config {
    state         = var.dnssec_enabled ? "on" : "off"
    non_existence = "nsec3"
  }
}

# Surface the DS record so the operator can register it at the parent zone
# (Cloudflare, for delegation chain of trust).
data "google_dns_keys" "this" {
  managed_zone = google_dns_managed_zone.this.id
}
