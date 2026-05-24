output "zone_name" {
  description = "Cloud DNS managed zone name."
  value       = google_dns_managed_zone.this.name
}

output "dns_name" {
  description = "Fully-qualified DNS name of the zone."
  value       = google_dns_managed_zone.this.dns_name
}

output "name_servers" {
  description = "Authoritative name servers. Add these as NS records at the parent zone (e.g. in Cloudflare for demarkus.io)."
  value       = google_dns_managed_zone.this.name_servers
}

output "ds_records" {
  description = "DS records to add at the parent zone for the DNSSEC chain of trust. Empty if DNSSEC is off."
  value = var.dnssec_enabled ? [
    for k in data.google_dns_keys.this.key_signing_keys : {
      key_tag     = k.key_tag
      algorithm   = k.algorithm
      digest_type = k.digests[0].type
      digest      = k.digests[0].digest
      ds_record   = k.ds_record
    }
  ] : []
}
