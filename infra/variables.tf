# ── Infrastructure shape ────────────────────────────────────────────────────

variable "zone" {
  description = "UpCloud zone to deploy into, e.g. fi-hel2."
  type        = string
}

variable "server_plan" {
  description = "UpCloud server plan, e.g. 1xCPU-2GB."
  type        = string
  default     = "1xCPU-2GB"
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
  description = "Size of the OS boot disk in GiB."
  type        = number
  default     = 25
}

variable "data_disk_size" {
  description = "Size of the dedicated encrypted data device in GiB (holds all SQLite DBs + uploads)."
  type        = number
  default     = 50
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
  description = "Apex domain, e.g. openkoutsi.example. The web app is served here."
  type        = string
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

variable "certbot_email" {
  description = "Contact email Let's Encrypt uses for expiry notices."
  type        = string
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

variable "llm_api_key" {
  description = "Server-side LLM API key (optional)."
  type        = string
  sensitive   = true
  default     = ""
}

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
