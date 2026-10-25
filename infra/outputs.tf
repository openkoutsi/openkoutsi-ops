output "public_ipv4" {
  description = "Public IPv4 of the VM. Point your registrar A records here."
  value       = upcloud_server.vm.network_interface[0].ip_address
}

output "hostnames" {
  description = "FQDNs that need A records at the registrar (all -> public_ipv4)."
  # Filtered so an optional host that is switched off (the Hammerhead bridge,
  # whose FQDN is empty then) is not listed as needing a record.
  value = { for name, fqdn in {
    landing           = local.landing_fqdn
    web               = local.web_fqdn
    api               = local.api_fqdn
    strava_bridge     = local.strava_bridge_fqdn
    wahoo_bridge      = local.wahoo_bridge_fqdn
    hammerhead_bridge = local.hammerhead_bridge_fqdn
    stats             = local.stats_fqdn
    logs              = local.logs_fqdn
    metrics           = local.metrics_fqdn
  } : name => fqdn if fqdn != "" }
}

output "data_storage_id" {
  description = "ID of the encrypted data device (holds all SQLite DBs + uploads)."
  value       = upcloud_storage.data.id
}
