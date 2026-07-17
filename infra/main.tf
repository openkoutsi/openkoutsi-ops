locals {
  # Fully-qualified hostnames derived from the apex domain.
  # The web app lives on the `app.` subdomain; the apex serves the static
  # landing page (openkoutsi-landing-page).
  landing_fqdn        = var.domain
  web_fqdn            = "${var.web_host}.${var.domain}"
  api_fqdn            = "${var.api_host}.${var.domain}"
  strava_bridge_fqdn  = "${var.strava_bridge_host}.${var.domain}"
  wahoo_bridge_fqdn   = "${var.wahoo_bridge_host}.${var.domain}"
  inbound_bridge_fqdn = "${var.inbound_bridge_host}.${var.domain}"
  stats_fqdn          = "${var.stats_host}.${var.domain}"
  logs_fqdn           = "${var.logs_host}.${var.domain}"
  metrics_fqdn        = "${var.metrics_host}.${var.domain}"

  data_mount = "/opt/openkoutsi/data"

  # Logs (nginx access/error + Vector's per-service files) stay on the VM's OS
  # disk, deliberately NOT on the encrypted data device — they are transient,
  # retention-pruned, and don't belong in the backed-up data volume. Only
  # /opt/openkoutsi/data is the mounted device; /opt/openkoutsi/logs is the OS disk.
  log_mount = "/opt/openkoutsi/logs"

  cloud_init = templatefile("${path.module}/cloud-init.yaml.tftpl", {
    data_mount      = local.data_mount
    log_mount       = local.log_mount
    ssh_public_keys = var.ssh_public_keys

    # Hostnames
    landing_fqdn       = local.landing_fqdn
    web_fqdn           = local.web_fqdn
    api_fqdn           = local.api_fqdn
    strava_bridge_fqdn = local.strava_bridge_fqdn
    wahoo_bridge_fqdn  = local.wahoo_bridge_fqdn
    stats_fqdn         = local.stats_fqdn
    logs_fqdn          = local.logs_fqdn
    metrics_fqdn       = local.metrics_fqdn
    certbot_email      = var.certbot_email
    certbot_staging    = var.certbot_staging ? "1" : "0"

    # Inbound email (issue #38) — a standard service on the public instance.
    inbound_bridge_fqdn   = local.inbound_bridge_fqdn
    inbound_email_address = var.inbound_email_address

    # Service-log retention (days) enforced by the oklog-prune timer.
    log_retention_days = var.log_retention_days

    # nginx access-log size cap enforced by the oknginx-logrotate timer.
    nginx_access_log_max_mb = var.nginx_access_log_max_mb
    nginx_access_log_keep   = var.nginx_access_log_keep

    # Non-secret app config. LLM base URL / model are admin-managed (InstanceSettings),
    # so they are not seeded here; LLM_ALLOWED_SERVERS is an env-only SSRF guard.
    llm_allowed_servers = var.llm_allowed_servers
    strava_client_id    = var.strava_client_id
    wahoo_client_id     = var.wahoo_client_id
    email_provider      = var.email_provider
    email_from          = var.email_from

    # Dashboard auth
    goaccess_htpasswd = var.goaccess_htpasswd

    # Secrets (written to /opt/openkoutsi/secrets/<name>, mode 0400)
    secret_key              = var.secret_key
    encryption_key          = var.encryption_key
    strava_client_secret    = var.strava_client_secret
    bridge_secret           = var.bridge_secret
    wahoo_client_secret     = var.wahoo_client_secret
    wahoo_bridge_secret     = var.wahoo_bridge_secret
    wahoo_webhook_token     = var.wahoo_webhook_token
    lettermint_api_key      = var.lettermint_api_key
    euromail_api_key        = var.euromail_api_key
    inbound_bridge_secret   = var.inbound_bridge_secret
    euromail_webhook_secret = var.euromail_webhook_secret

    # Optional private-registry login
    ghcr_username = var.ghcr_username
    ghcr_token    = var.ghcr_token

    # Rendered compose + config files
    docker_compose      = file("${path.module}/../compose/docker-compose.yml")
    nginx_conf          = file("${path.module}/../compose/nginx/nginx.conf")
    nginx_api           = templatefile("${path.module}/../compose/nginx/conf.d/api.conf", { server_name = local.api_fqdn })
    nginx_web           = templatefile("${path.module}/../compose/nginx/conf.d/web.conf", { server_name = local.web_fqdn })
    nginx_landing       = templatefile("${path.module}/../compose/nginx/conf.d/landing.conf", { server_name = local.landing_fqdn })
    nginx_strava_bridge = templatefile("${path.module}/../compose/nginx/conf.d/strava-bridge.conf", { server_name = local.strava_bridge_fqdn })
    nginx_wahoo_bridge  = templatefile("${path.module}/../compose/nginx/conf.d/wahoo-bridge.conf", { server_name = local.wahoo_bridge_fqdn })
    nginx_inbound       = templatefile("${path.module}/../compose/nginx/conf.d/inbound-bridge.conf", { server_name = local.inbound_bridge_fqdn })
    nginx_goaccess      = templatefile("${path.module}/../compose/nginx/conf.d/goaccess.conf", { server_name = local.stats_fqdn })
    nginx_logs          = templatefile("${path.module}/../compose/nginx/conf.d/logs.conf", { server_name = local.logs_fqdn })
    nginx_metrics       = templatefile("${path.module}/../compose/nginx/conf.d/metrics.conf", { server_name = local.metrics_fqdn })
    goaccess_conf       = file("${path.module}/../compose/goaccess/goaccess.conf")
    vector_conf         = file("${path.module}/../compose/vector/vector.yaml")
    netdata_conf        = file("${path.module}/../compose/netdata/netdata.conf")
    okdeploy_service    = file("${path.module}/../systemd/okdeploy.service")
    okdeploy_timer      = file("${path.module}/../systemd/okdeploy.timer")
    okdeploy_pull       = file("${path.module}/../scripts/okdeploy-pull.sh")
    oklog_prune_service = file("${path.module}/../systemd/oklog-prune.service")
    oklog_prune_timer   = file("${path.module}/../systemd/oklog-prune.timer")
    oklog_prune         = file("${path.module}/../scripts/oklog-prune.sh")
    init_certs          = file("${path.module}/../scripts/init-certs.sh")

    # nginx access-log size-cap unit + timer + script
    oknginx_logrotate_service = file("${path.module}/../systemd/oknginx-logrotate.service")
    oknginx_logrotate_timer   = file("${path.module}/../systemd/oknginx-logrotate.timer")
    oknginx_logrotate         = file("${path.module}/../scripts/oknginx-logrotate.sh")
  })
}

# Dedicated encrypted block device for all sensitive data (SQLite DBs + uploads),
# kept separate from the OS disk.
resource "upcloud_storage" "data" {
  title   = "${var.hostname}-data"
  size    = var.data_disk_size
  zone    = var.zone
  tier    = "maxiops"
  encrypt = true

  # Daily UpCloud-managed backups of the data device, retained for a week. These
  # are snapshot-style backups stored as separate backup storage by UpCloud — a
  # different volume from the live device, protecting against accidental data
  # loss / device corruption. NOTE: UpCloud backups live in the SAME zone as the
  # source storage; they are not cross-region, so they are not a full DR/offsite
  # solution. For offsite copies, also stream dumps to Object Storage elsewhere.
  backup_rule {
    interval  = var.backup_interval
    time      = var.backup_time
    retention = var.backup_retention
  }

  # Guard the live data device against accidental destruction. With this set,
  # `tofu destroy` (and any plan that would delete this storage) fails loudly
  # instead of wiping every SQLite DB and upload. To intentionally tear the
  # volume down (e.g. decommissioning staging), remove this block first.
  lifecycle {
    prevent_destroy = true
  }
}

resource "upcloud_server" "vm" {
  hostname = var.hostname
  zone     = var.zone
  plan     = var.server_plan

  # The UpCloud metadata service must be enabled to boot from a cloud-init
  # template — that's how cloud-init reads user_data. Without it UpCloud rejects
  # the clone with METADATA_DISABLED_ON_CLOUD-INIT (409).
  metadata = true

  # OS boot disk (encrypted as well for defense in depth).
  template {
    storage = var.os_template
    size    = var.os_disk_size
    encrypt = true
  }

  # Attach the dedicated encrypted data device. Pinned to virtio position 1
  # (the boot template is virtio:0) so it is consistently /dev/vdb, which
  # cloud-init formats and mounts.
  storage_devices {
    storage          = upcloud_storage.data.id
    address          = "virtio"
    address_position = "1"
  }

  # UpCloud v5 does not create interfaces implicitly, so they must be declared.
  # The provider's interface index is 1-based. The public IPv4 is declared first
  # so it is network_interface[0] (its address is exported as public_ipv4 and is
  # what the A records point at). The utility interface sits on UpCloud's
  # internal SDN (no extra cost) for management traffic.
  network_interface {
    type              = "public"
    ip_address_family = "IPv4"
    index             = 1
  }

  network_interface {
    type  = "utility"
    index = 2
  }

  login {
    user            = "deploy"
    keys            = var.ssh_public_keys
    create_password = false
  }

  user_data = local.cloud_init
}

# Default-deny inbound firewall: public 80/443, SSH only from admin_cidr, egress open.
resource "upcloud_firewall_rules" "vm" {
  server_id = upcloud_server.vm.id

  dynamic "firewall_rule" {
    for_each = ["80", "443"]
    content {
      action                 = "accept"
      direction              = "in"
      family                 = "IPv4"
      protocol               = "tcp"
      destination_port_start = firewall_rule.value
      destination_port_end   = firewall_rule.value
    }
  }

  firewall_rule {
    action                 = "accept"
    direction              = "in"
    family                 = "IPv4"
    protocol               = "tcp"
    source_address_start   = cidrhost(var.admin_cidr, 0)
    source_address_end     = cidrhost(var.admin_cidr, -1)
    destination_port_start = "22"
    destination_port_end   = "22"
  }

  # Allow already-established/related return traffic and ICMP, then deny the rest.
  firewall_rule {
    action    = "accept"
    direction = "in"
    family    = "IPv4"
    protocol  = "icmp"
  }

  firewall_rule {
    action    = "drop"
    direction = "in"
    family    = "IPv4"
  }
}
