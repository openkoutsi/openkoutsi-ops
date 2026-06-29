locals {
  # Fully-qualified hostnames derived from the apex domain.
  web_fqdn           = var.domain
  api_fqdn           = "${var.api_host}.${var.domain}"
  strava_bridge_fqdn = "${var.strava_bridge_host}.${var.domain}"
  wahoo_bridge_fqdn  = "${var.wahoo_bridge_host}.${var.domain}"
  stats_fqdn         = "${var.stats_host}.${var.domain}"

  data_mount = "/opt/openkoutsi/data"

  cloud_init = templatefile("${path.module}/cloud-init.yaml.tftpl", {
    data_mount      = local.data_mount
    ssh_public_keys = var.ssh_public_keys

    # Hostnames
    web_fqdn           = local.web_fqdn
    api_fqdn           = local.api_fqdn
    strava_bridge_fqdn = local.strava_bridge_fqdn
    wahoo_bridge_fqdn  = local.wahoo_bridge_fqdn
    stats_fqdn         = local.stats_fqdn
    certbot_email      = var.certbot_email
    certbot_staging    = var.certbot_staging ? "1" : "0"

    # Non-secret app config. LLM base URL / model are admin-managed (InstanceSettings),
    # so they are not seeded here; LLM_ALLOWED_SERVERS is an env-only SSRF guard.
    llm_allowed_servers = var.llm_allowed_servers
    strava_client_id    = var.strava_client_id
    wahoo_client_id     = var.wahoo_client_id

    # Dashboard auth
    goaccess_htpasswd = var.goaccess_htpasswd

    # Secrets (written to /opt/openkoutsi/secrets/<name>, mode 0400)
    secret_key           = var.secret_key
    encryption_key       = var.encryption_key
    llm_api_key          = var.llm_api_key
    strava_client_secret = var.strava_client_secret
    bridge_secret        = var.bridge_secret
    wahoo_client_secret  = var.wahoo_client_secret
    wahoo_bridge_secret  = var.wahoo_bridge_secret
    wahoo_webhook_token  = var.wahoo_webhook_token

    # Optional private-registry login
    ghcr_username = var.ghcr_username
    ghcr_token    = var.ghcr_token

    # Rendered compose + config files
    docker_compose      = file("${path.module}/../compose/docker-compose.yml")
    nginx_conf          = file("${path.module}/../compose/nginx/nginx.conf")
    nginx_api           = templatefile("${path.module}/../compose/nginx/conf.d/api.conf", { server_name = local.api_fqdn })
    nginx_web           = templatefile("${path.module}/../compose/nginx/conf.d/web.conf", { server_name = local.web_fqdn })
    nginx_strava_bridge = templatefile("${path.module}/../compose/nginx/conf.d/strava-bridge.conf", { server_name = local.strava_bridge_fqdn })
    nginx_wahoo_bridge  = templatefile("${path.module}/../compose/nginx/conf.d/wahoo-bridge.conf", { server_name = local.wahoo_bridge_fqdn })
    nginx_goaccess      = templatefile("${path.module}/../compose/nginx/conf.d/goaccess.conf", { server_name = local.stats_fqdn })
    goaccess_conf       = templatefile("${path.module}/../compose/goaccess/goaccess.conf", { stats_fqdn = local.stats_fqdn })
    okdeploy_service    = file("${path.module}/../systemd/okdeploy.service")
    okdeploy_timer      = file("${path.module}/../systemd/okdeploy.timer")
    okdeploy_pull       = file("${path.module}/../scripts/okdeploy-pull.sh")
    init_certs          = file("${path.module}/../scripts/init-certs.sh")
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
}

resource "upcloud_server" "vm" {
  hostname = var.hostname
  zone     = var.zone
  plan     = var.server_plan

  # OS boot disk (encrypted as well for defense in depth).
  template {
    storage = var.os_template
    size    = var.os_disk_size
    encrypt = true
  }

  # Attach the dedicated encrypted data device.
  storage_devices {
    storage = upcloud_storage.data.id
    address = "virtio:1"
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
