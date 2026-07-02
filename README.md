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
  separate from the OS disk. The device is `prevent_destroy`-guarded so a stray
  `tofu destroy` can't wipe it, and UpCloud takes **daily backups retained for a
  week** (same-zone snapshots — see [Backups](#backups-and-restore)).

## Layout

```
infra/        OpenTofu — UpCloud server + encrypted storage (backed up) + firewall + cloud-init
compose/      docker-compose.yml, nginx + certbot + GoAccess + Vector config, env.example
systemd/      okdeploy.service + okdeploy.timer (poll loop), oklog-prune.* (log retention)
scripts/      okdeploy-pull.sh (pull + recreate changed services), oklog-prune.sh (prune old logs)
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

Alongside the app images the stack runs a few pinned third-party containers:
`nginx` (TLS/reverse proxy), `certbot` (TLS renewal), `allinurl/goaccess`
(nginx-log dashboard), `timberio/vector` (collects every container's stdout into
per-service log files), `amir20/dozzle` (live log viewer), and `netdata/netdata`
(host + container performance metrics). See [Observability](#observability) for
the logging and metrics pieces.

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
| `logs`           | Dozzle log viewer |
| `metrics`        | Netdata metrics dashboard |

### 5. TLS certificates (first-boot bootstrap)

nginx terminates TLS with a **single Let's Encrypt SAN cert** (lineage
`openkoutsi`) covering all seven hostnames (apex, `api`, `bridge`, `wahoo-bridge`,
`stats`, `logs`, `metrics`). Because a fresh VM has no cert yet,
`scripts/init-certs.sh` breaks the usual nginx⇄certbot deadlock: it writes a
throwaway self-signed cert so nginx can start, brings nginx up, obtains the real
cert over the HTTP-01 webroot challenge, then reloads nginx onto it.

cloud-init runs this automatically at the end of first boot — but the real cert
can only be issued **once the registrar A records (step 4) resolve to the VM**.
On a brand-new VM that's usually not true yet, so the first attempt fails
gracefully and nginx keeps serving the temporary self-signed cert. After DNS has
propagated, issue the real cert:

```bash
ssh deploy@<ip>
cd /opt/openkoutsi && sudo bash scripts/init-certs.sh
```

> **Run it with `sudo`.** cloud-init runs this as root at first boot, and the
> certbot container writes the cert files as root. Re-running it as the `deploy`
> user fails silently — `openssl` can't overwrite the root-owned cert files, so
> the script aborts right after the "writing temporary self-signed cert" line.

Tips:
- Set `certbot_staging = true` while testing to use Let's Encrypt's staging CA
  (untrusted certs, no rate limits); flip to `false` and re-run for real certs.
- Force a re-issue at any time with `sudo FORCE_CERT=1 bash scripts/init-certs.sh`.
- Renewals are automatic: the `certbot` service renews every 12h and nginx
  reloads every 6h to pick up the new cert.

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
- **Live container logs (shell):** `docker compose -f /opt/openkoutsi/docker-compose.yml logs -f <svc>`
- **Access dashboard (nginx traffic):** `https://stats.<domain>`. Basic-auth
  credentials come from the `goaccess_htpasswd` variable (generate with
  `htpasswd -nB admin`), which cloud-init writes to `/opt/openkoutsi/nginx/.htpasswd`.
- **Service logs (web/backend/bridges):** see [Observability](#observability).
- **Performance metrics (CPU/memory/disk/network):** `https://metrics.<domain>`
  (Netdata) — see [Observability](#observability).

### Observability

Three complementary views, all behind the same basic-auth (`goaccess_htpasswd`):

- **nginx traffic** — GoAccess renders the nginx access log as a real-time HTML
  report at `https://stats.<domain>` (see above).
- **Server & container performance** — a **Netdata** container exposes a live
  dashboard at `https://metrics.<domain>`: CPU utilisation, memory/swap, disk I/O
  and space, network, and per-container resource usage. Use it to judge whether the
  VM plan is over- or under-sized before resizing (see [Scaling](#scaling)). It
  reads host metrics through read-only `/proc`, `/sys` and the Docker socket, and
  keeps a small on-disk history in Docker named volumes (`netdata_lib` /
  `netdata_cache`) on the OS disk — deliberately off the encrypted data device, like
  the logs, since it is transient and self-pruned. To stay light on the 2 GB VM its
  config (`compose/netdata/netdata.conf`) disables Netdata Cloud and the ML
  anomaly-detection engine, samples every 2s, and caps the metrics DB at 256 MB;
  raise `dbengine multihost disk space MB` there for longer retention.
- **Service logs** — the application containers (backend, web, both bridges) log
  to stdout, which is ephemeral and wiped whenever the poll loop recreates a
  container. A **Vector** collector tails every container's output through the
  Docker API and writes it as per-service, daily-rotated files to the
  `service_logs` volume on the VM's OS disk — **not** the encrypted data device
  (`${LOG_MOUNT}/service_logs/<container>/<date>.log`). View them either:
  - **In the browser:** `https://logs.<domain>` — a **Dozzle** live log viewer
    (real-time tail/search across all containers).
  - **On the box:** `tail -f`/`grep` the files under `${LOG_MOUNT}/service_logs/`.

  Retention is enforced by the `oklog-prune.timer` (daily), which deletes files
  older than `LOG_RETENTION_DAYS` (default 30, tunable via the `log_retention_days`
  variable). nginx logs are excluded from Vector since GoAccess already covers them.

  Both the nginx logs (`${LOG_MOUNT}/nginx_logs`) and these service logs live on
  the VM's OS disk (`LOG_MOUNT`, default `/opt/openkoutsi/logs`), kept off the
  encrypted data device: they are transient and retention-pruned, so they don't
  belong in the backed-up data volume.

### Backups and restore

The encrypted data device (all SQLite DBs + uploads) is backed up by UpCloud on a
schedule defined in the IaC (`backup_rule` on `upcloud_storage.data`): **daily at
01:00 UTC, retained 7 days** by default. Tune with `backup_interval` /
`backup_time` / `backup_retention`.

- **Scope / limits:** these are UpCloud-managed snapshots stored as separate backup
  storage (a different volume from the live device), so they cover accidental data
  loss and device corruption. They live in the **same zone** as the source storage,
  so they are *not* an offsite/cross-region DR copy. If you need offsite copies,
  add a job that streams `sqlite3 .backup` dumps to Object Storage in another region.
- **Inspect backups:** UpCloud console → the `<hostname>-data` storage → *Backups*,
  or via the API/CLI (`upctl storage backup …`).
- **Restore:** restore the chosen backup over the data device (or restore to a new
  storage and re-attach it) from the UpCloud console/CLI, then `docker compose up -d`
  on the VM. The backend runs migrations on start, so a slightly older schema is
  brought forward automatically.
- **Accidental-destroy guard:** `upcloud_storage.data` has
  `lifecycle { prevent_destroy = true }`, so `tofu destroy` and any plan that would
  delete the device fail loudly. To intentionally decommission it (e.g. tearing down
  staging), remove that `lifecycle` block first — see Verification below.

## Scaling

openkoutsi is a single, stateful VM (SQLite on one encrypted device), so it
**scales vertically** — resize the box to a larger UpCloud plan. A plan change is
an **in-place** resize: same VM, **same IP, no DNS change**. See
**[SCALING.md](SCALING.md)** for the step-by-step, the OS-disk/zone caveats, and
when to fall back to the fresh-VM cutover below instead.

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

> The static checks below run automatically on every pull request via
> `.github/workflows/ci.yml` (OpenTofu `fmt`/`validate`/`tflint`, `shellcheck`,
> `docker compose config`, and `actionlint`). Run them locally before pushing to
> get the same feedback faster.

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
5. `tofu destroy` removes the staging resources. The data device is
   `prevent_destroy`-guarded, so destroy will refuse until you remove the
   `lifecycle` block on `upcloud_storage.data` (or delete the volume manually in
   the console) — intentional, so production data can't be torn down by accident.

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
