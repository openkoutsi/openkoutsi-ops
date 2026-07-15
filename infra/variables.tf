# ── Infrastructure shape ────────────────────────────────────────────────────

variable "zone" {
  description = "UpCloud zone to deploy into. Defaults to fi-hel1 (where the STARTER-2xCPU-2GB plan is available)."
  type        = string
  default     = "fi-hel1"
}

variable "server_plan" {
  description = "UpCloud server plan. Defaults to the Starter tier STARTER-2xCPU-2GB (2 cores, 2 GB RAM, 30 GB bundled storage, ~€8/mo)."
  type        = string
  default     = "STARTER-2xCPU-2GB"
}

variable "hostname" {
  description = "Hostname of the VM, e.g. openkoutsi-prod."
  type        = string
  default     = "openkoutsi-prod"
}

variable "os_template" {
  description = "OS template title or UUID for the boot disk."
  type        = string
  default     = "Ubuntu Server 24.04 LTS (Noble Numbat)"
}

variable "os_disk_size" {
  description = "Size of the OS boot disk in GiB. Matches the STARTER-2xCPU-2GB plan's 30 GB bundled storage."
  type        = number
  default     = 30
}

variable "data_disk_size" {
  description = "Size of the dedicated encrypted data device in GiB (holds all SQLite DBs + uploads)."
  type        = number
  default     = 50
}

# ── Data backups (UpCloud-managed, same-zone snapshots) ─────────────────────

variable "backup_interval" {
  description = "How often UpCloud backs up the data device: daily or a specific weekday (mon..sun)."
  type        = string
  default     = "daily"

  validation {
    condition     = contains(["daily", "mon", "tue", "wed", "thu", "fri", "sat", "sun"], var.backup_interval)
    error_message = "backup_interval must be one of: daily, mon, tue, wed, thu, fri, sat, sun."
  }
}

variable "backup_time" {
  description = "Time of day the data backup runs, in UTC \"HHMM\" 24h form (e.g. 0100)."
  type        = string
  default     = "0100"

  validation {
    condition     = can(regex("^([01][0-9]|2[0-3])[0-5][0-9]$", var.backup_time))
    error_message = "backup_time must be a 24h HHMM string between 0000 and 2359."
  }
}

variable "backup_retention" {
  description = "Number of days UpCloud keeps each data-device backup before pruning it."
  type        = number
  default     = 7

  validation {
    condition     = var.backup_retention >= 1 && var.backup_retention <= 1095
    error_message = "backup_retention must be between 1 and 1095 days."
  }
}

# ── Service logs (Vector → files on the data device, pruned on a timer) ─────

variable "log_retention_days" {
  description = "Days to keep per-service log files under the service_logs volume before the oklog-prune timer deletes them."
  type        = number
  default     = 30

  validation {
    condition     = var.log_retention_days >= 1 && var.log_retention_days <= 3650
    error_message = "log_retention_days must be between 1 and 3650 days."
  }
}

variable "nginx_access_log_max_mb" {
  description = "Size cap (MB) for the nginx access.log before the oknginx-logrotate timer rotates it."
  type        = number
  default     = 100

  validation {
    condition     = var.nginx_access_log_max_mb >= 1 && var.nginx_access_log_max_mb <= 10240
    error_message = "nginx_access_log_max_mb must be between 1 and 10240 MB."
  }
}

variable "nginx_access_log_keep" {
  description = "Number of compressed nginx access-log generations to retain after rotation."
  type        = number
  default     = 5

  validation {
    condition     = var.nginx_access_log_keep >= 1 && var.nginx_access_log_keep <= 100
    error_message = "nginx_access_log_keep must be between 1 and 100."
  }
}

# ── Access control ──────────────────────────────────────────────────────────

variable "admin_cidr" {
  description = "CIDR allowed to reach SSH (port 22). Everything else is denied inbound except 80/443."
  type        = string
}

variable "ssh_public_keys" {
  description = "SSH public keys installed for the deploy user."
  type        = list(string)
}

# ── DNS / domains ───────────────────────────────────────────────────────────
# UpCloud has no managed DNS in the provider — A records are set at the registrar
# (see README). These values drive nginx server_name and certbot domains only.

variable "domain" {
  description = "Apex domain, e.g. openkoutsi.example. The static landing page is served here."
  type        = string
}

variable "web_host" {
  description = "Hostname for the web app (subdomain of the apex domain)."
  type        = string
  default     = "app"
}

variable "api_host" {
  description = "Hostname for the API."
  type        = string
  default     = "api"
}

variable "strava_bridge_host" {
  description = "Hostname for the Strava webhook bridge."
  type        = string
  default     = "bridge"
}

variable "wahoo_bridge_host" {
  description = "Hostname for the Wahoo webhook bridge."
  type        = string
  default     = "wahoo-bridge"
}

variable "stats_host" {
  description = "Hostname for the GoAccess access-log dashboard."
  type        = string
  default     = "stats"
}

variable "logs_host" {
  description = "Hostname for the Dozzle live service-log viewer."
  type        = string
  default     = "logs"
}

variable "metrics_host" {
  description = "Hostname for the Netdata performance-metrics dashboard."
  type        = string
  default     = "metrics"
}

variable "certbot_email" {
  description = "Contact email Let's Encrypt uses for expiry notices."
  type        = string
}

variable "certbot_staging" {
  description = "Use the Let's Encrypt staging environment (untrusted certs, no rate limits). Set true while testing first-boot, then false for real certs."
  type        = bool
  default     = false
}

# ── Non-secret application config ───────────────────────────────────────────

# LLM base URL / model / API key are configured on the admin settings page
# (InstanceSettings), not via deployment env — so they are intentionally absent here.

variable "llm_allowed_servers" {
  description = "Comma-separated allowlist of LLM base URLs users may pick (env-only SSRF guard, not an instance setting)."
  type        = string
  default     = ""
}

variable "strava_client_id" {
  description = "Strava OAuth client ID (not secret)."
  type        = string
  default     = ""
}

variable "wahoo_client_id" {
  description = "Wahoo OAuth client ID (not secret)."
  type        = string
  default     = ""
}

variable "email_provider" {
  description = "Outbound email provider (issue #15): \"lettermint\" or \"euromail\"."
  type        = string
  default     = "lettermint"
}

variable "email_from" {
  description = "Sender address for outbound transactional email. Empty keeps self-serve signup/reset disabled."
  type        = string
  default     = ""
}

# ── GoAccess dashboard auth ─────────────────────────────────────────────────

variable "goaccess_htpasswd" {
  description = "An htpasswd line (user:hash) protecting the stats dashboard. Generate with: htpasswd -nB admin"
  type        = string
  sensitive   = true
}

# ── Secrets (delivered to /run/secrets via Docker secrets) ──────────────────
# File names on the VM match these (lowercase) pydantic field names so that
# pydantic-settings' secrets_dir=/run/secrets reads them.

variable "secret_key" {
  description = "Backend JWT signing key (>= 32 chars). python -c \"import secrets; print(secrets.token_hex(32))\""
  type        = string
  sensitive   = true
}

variable "encryption_key" {
  description = "Fernet key for field-level encryption. python -c \"from cryptography.fernet import Fernet; print(Fernet.generate_key().decode())\""
  type        = string
  sensitive   = true
}

# LLM API key is admin-managed (InstanceSettings.llm_api_key_enc) — no global
# deployment fallback, so there is intentionally no llm_api_key variable/secret.

variable "strava_client_secret" {
  description = "Strava OAuth client secret (shared by backend + strava bridge)."
  type        = string
  sensitive   = true
  default     = ""
}

variable "bridge_secret" {
  description = "Shared bearer secret between backend and the Strava bridge."
  type        = string
  sensitive   = true
  default     = ""
}

variable "wahoo_client_secret" {
  description = "Wahoo OAuth client secret (backend)."
  type        = string
  sensitive   = true
  default     = ""
}

variable "wahoo_bridge_secret" {
  description = "Shared bearer secret between backend and the Wahoo bridge (backend side)."
  type        = string
  sensitive   = true
  default     = ""
}

variable "wahoo_webhook_token" {
  description = "Token Wahoo embeds in webhook payloads (Wahoo bridge side)."
  type        = string
  sensitive   = true
  default     = ""
}

variable "lettermint_api_key" {
  description = "Lettermint API token for outbound email (issue #15). Empty keeps email disabled."
  type        = string
  sensitive   = true
  default     = ""
}

variable "euromail_api_key" {
  description = "EuroMail API token for outbound email (issue #15). Empty keeps email disabled."
  type        = string
  sensitive   = true
  default     = ""
}

# ── GHCR (optional — images are public by default) ──────────────────────────

variable "ghcr_username" {
  description = "GHCR username for docker login. Leave empty when packages are public."
  type        = string
  default     = ""
}

variable "ghcr_token" {
  description = "Read-only GHCR PAT for docker login. Leave empty when packages are public."
  type        = string
  sensitive   = true
  default     = ""
}
