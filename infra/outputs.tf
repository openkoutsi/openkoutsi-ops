output "public_ipv4" {
  description = "Public IPv4 of the VM. Point your registrar A records here."
  value       = upcloud_server.vm.network_interface[0].ip_address
}

output "hostnames" {
  description = "FQDNs that need A records at the registrar (all -> public_ipv4)."
  value = {
    web           = local.web_fqdn
    api           = local.api_fqdn
    strava_bridge = local.strava_bridge_fqdn
    wahoo_bridge  = local.wahoo_bridge_fqdn
    stats         = local.stats_fqdn
  }
}

output "data_storage_id" {
  description = "ID of the encrypted data device (holds all SQLite DBs + uploads)."
  value       = upcloud_storage.data.id
}
