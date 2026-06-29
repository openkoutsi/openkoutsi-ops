# openkoutsi-ops

Infrastructure-as-code and deployment configuration for
[openkoutsi](https://github.com/openkoutsi/openkoutsi-backend). This repo is the
**Part B** deliverable of
[openkoutsi-backend#5](https://github.com/openkoutsi/openkoutsi-backend/issues/5):
a containerized, **poll-based** deployment on UpCloud, fully rebuildable from code.

## Model

- **CI builds, the VM pulls.** Images are built and pushed to GHCR by CI in the
  application repos. The VM never builds and holds no source — it only pulls
  finished images. There is **no inbound CI→VM SSH**.
- **Polling, not push.** A systemd timer (`okdeploy.timer`, every 2 min) runs
  `scripts/okdeploy-pull.sh` → `docker compose pull && up -d`, which recreates
  only services whose image digest changed. A poll where nothing moved is a
  no-op.
- **Secrets as files.** Secrets are delivered as individual files under
  `/opt/openkoutsi/secrets/<name>` and mounted by Compose at `/run/secrets/<name>`,
  where the apps read them (pydantic-settings `secrets_dir=/run/secrets`). They
  are never environment variables and never committed to git. File names match
  the lowercase settings field names.
- **Sensitive data on an encrypted device.** All SQLite DBs and uploads live on a
  dedicated UpCloud **encrypted** storage device mounted at `/opt/openkoutsi/data`,
  separate from the OS disk.

## Layout

```
infra/        OpenTofu — UpCloud server + encrypted storage + firewall + cloud-init
compose/      docker-compose.yml, nginx + certbot + GoAccess config, env.example
systemd/      okdeploy.service + okdeploy.timer (the poll loop)
scripts/      okdeploy-pull.sh (pull + recreate changed services)
```

The VM is configured **by cloud-init only** (`infra/cloud-init.yaml.tftpl`):
OpenTofu renders it with `templatefile`, embedding the compose/nginx/systemd files
and writing secrets from TF variables. To change the box, re-render and re-provision.

## Images

| Service        | Image                                          | Port | Built in   |
|----------------|------------------------------------------------|------|------------|
| Backend        | `ghcr.io/openkoutsi/openkoutsi-backend`        | 8000 | backend    |
| Strava bridge  | `ghcr.io/openkoutsi/openkoutsi-strava-bridge`  | 8084 | backend    |
| Wahoo bridge   | `ghcr.io/openkoutsi/openkoutsi-wahoo-bridge`   | 8085 | backend    |
| Web frontend   | `ghcr.io/openkoutsi/openkoutsi-web`            | 3000 | web        |

The VM tracks the `latest` tag; CI also pushes immutable `sha-<sha>` tags for
rollback. **Packages are public**, so the VM needs no pull credentials. (To switch
to private packages, set `ghcr_username`/`ghcr_token` and cloud-init will
`docker login`.)

## Provisioning

### 1. Remote state (one-time)

State contains secrets, so it lives in UpCloud Managed Object Storage
(S3-compatible). Create a bucket + access keys in the UpCloud console, then:

```bash
cd infra
cp backend.hcl.example backend.hcl     # edit bucket/endpoint/region
export AWS_ACCESS_KEY_ID=...           # Object Storage access key
export AWS_SECRET_ACCESS_KEY=...       # Object Storage secret key
export UPCLOUD_USERNAME=...            # UpCloud API user
export UPCLOUD_PASSWORD=...            # UpCloud API password
tofu init -backend-config=backend.hcl
```

### 2. Inputs

```bash
cp terraform.tfvars.example terraform.tfvars   # non-secret values
```

Provide secrets via `TF_VAR_*` env vars or a gitignored `secrets.auto.tfvars`
(both `*.tfvars` except `*.example` and `*.auto.tfvars` are gitignored). Generate
fresh values:

```bash
# secret_key / bridge_secret / wahoo_bridge_secret / wahoo_webhook_token
python -c "import secrets; print(secrets.token_hex(32))"
# encryption_key
python -c "from cryptography.fernet import Fernet; print(Fernet.generate_key().decode())"
# goaccess_htpasswd
htpasswd -nB admin
```

### 3. Apply

```bash
tofu fmt -check
tofu validate
tofu plan
tofu apply
```

`tofu apply` provisions a **fresh** VM; cloud-init installs Docker, mounts the
encrypted device, writes config + secrets, and brings the stack up. Watch it
finish with `ssh deploy@<ip> cloud-init status --wait`.

### 4. DNS (registrar)

UpCloud has no managed DNS in the provider, so set these **A records at your
registrar**, all pointing at the `public_ipv4` output:

| Record           | Host             |
|------------------|------------------|
| `@` (apex)       | web frontend     |
| `api`            | backend API      |
| `bridge`         | Strava bridge    |
| `wahoo-bridge`   | Wahoo bridge     |
| `stats`          | GoAccess report  |

Certbot obtains TLS certs via the nginx webroot challenge once DNS resolves.

## Operations

- **Deploy a new version:** merge to `main` in the app repo → CI publishes a new
  `latest` → within ~2 min the VM recreates only the changed service. Nothing to
  do on the box.
- **Rollback:** pin a service to a prior immutable tag and bring it up:
  ```bash
  cd /opt/openkoutsi
  docker compose pull backend
  # or pin: edit image to ...:sha-<good-sha>
  docker compose up -d backend
  ```
- **Force a poll now:** `sudo systemctl start okdeploy.service`
- **Logs:** `docker compose -f /opt/openkoutsi/docker-compose.yml logs -f <svc>`
- **Access dashboard:** `https://stats.<domain>` (basic-auth).

## Fresh-VM cutover (from the existing host)

1. `tofu apply` the new VM and let cloud-init finish.
2. Stop writers on the old host, then copy data onto the new encrypted volume:
   ```bash
   # backend: registry.db + per-user DBs + uploads
   rsync -a old:/path/to/data/  deploy@<new-ip>:/opt/openkoutsi/data/backend/
   # each bridge DB
   rsync -a old:/path/strava_bridge/bridge.db deploy@<new-ip>:/opt/openkoutsi/data/strava_bridge/
   rsync -a old:/path/wahoo_bridge/bridge.db  deploy@<new-ip>:/opt/openkoutsi/data/wahoo_bridge/
   ```
3. `docker compose up -d` (the backend image runs migrations on start — Part A).
4. Verify (below), then cut the registrar DNS to `<new-ip>` and decommission the
   old VM.

## Verification

Static / dry-run (no UpCloud account needed):

```bash
# Compose parses and resolves all secret/env references
docker compose -f compose/docker-compose.yml --env-file compose/env.example config >/dev/null

# Shell + OpenTofu
bash -n scripts/okdeploy-pull.sh
cd infra && tofu fmt -check && tofu init -backend=false && tofu validate
```

Live (staging):

1. `tofu apply` → `cloud-init status --wait` completes.
2. Firewall blocks SSH from non-admin IPs; 80/443 serve.
3. API, web, both bridge webhook URLs and the GoAccess report load behind nginx
   with valid Let's Encrypt TLS.
4. Push a trivial backend change → new `latest` → within the timer interval only
   the backend container is recreated (`docker compose ps` shows a new image id).
5. `tofu destroy` cleanly removes the staging resources.

## Security notes

- VM only pulls images — no inbound CI SSH key, no source/build on the box.
- Data volumes sit on the VM's encrypted disk; `encryption_key` is a Docker secret
  on the box, separate from disk-encryption keys (defense in depth).
- Containers run as published images' non-root user; only nginx is exposed
  (80/443). SSH is restricted to `admin_cidr`.
- With plain Compose, `secrets:` are bind-mounted files (not Swarm-encrypted at
  rest) — the gain over `.env` is that secrets are never exposed as environment
  variables (no leak via `docker inspect` / `/proc/<pid>/environ`) and are
  `0400`-restricted on the encrypted volume.
