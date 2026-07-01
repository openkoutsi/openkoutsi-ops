# Scaling openkoutsi

openkoutsi is a **single-VM** deployment: the backend and both bridges are stateful
services backed by **SQLite databases on one encrypted device** (`/opt/openkoutsi/data`).
There is no shared database tier and no load balancer, so the app **scales
vertically** — you give the one VM more CPU/RAM by moving it to a larger UpCloud
plan. Horizontal scaling (multiple app VMs behind a balancer) is **not supported**
by this stack and would require a different data architecture.

This doc covers the two ways the box changes size:

- **[Resize in place](#resize-in-place-recommended)** — bump the plan, `tofu apply`.
  Same VM, **same IP, no DNS change.** This is the normal path.
- **[Fresh-VM cutover](#fresh-vm-cutover)** — build a new VM and migrate data to it.
  New IP, **DNS change required.** Only when a resize can't do the job.

## Resize in place (recommended)

The VM plan is a single input, [`server_plan`](infra/variables.tf) (default
`STARTER-2xCPU-2GB`), consumed by `upcloud_server.vm.plan` in
[`infra/main.tf`](infra/main.tf). `plan` is an **in-place** attribute on
`upcloud_server` — it is *not* a force-replacement — so OpenTofu resizes the
existing server rather than rebuilding it.

1. **Pick a larger plan.** e.g. `STARTER-4xCPU-8GB`, or a `CustomPlan` shape. See
   the UpCloud plan catalogue for what's available in your `zone`.
2. **Set it** in `terraform.tfvars` (or via `-var`/`TF_VAR_server_plan`):
   ```hcl
   server_plan = "STARTER-4xCPU-8GB"
   ```
3. **Apply:**
   ```bash
   cd infra
   tofu plan     # confirm the server shows an in-place update, not replacement
   tofu apply
   ```
4. **Done — no DNS change.** The VM keeps its public IPv4 (`public_ipv4` output),
   so the registrar A records still point at the right place.

> **Always read the plan output.** If `tofu plan` shows the server being
> **destroyed and re-created** (`-/+`) instead of updated in place (`~`), stop —
> that would drop the IP and rebuild the box. That's the cutover path below, not a
> resize. A plain `plan` change should never force replacement; if it does,
> something else in the diff (zone, template) is driving it.

### What to know

- **Brief downtime.** UpCloud resizes with a **stop → resize → start** cycle, so
  expect a reboot-length outage. It is not zero-downtime.
- **Your data is safe.** All SQLite DBs and uploads live on the *separate*
  `upcloud_storage.data` device, which is `prevent_destroy`-guarded. A resize
  touches only the compute/OS instance, never that volume.
- **Mind the OS disk vs. the plan's bundled storage.** The boot disk is fixed at
  [`os_disk_size`](infra/variables.tf) (default 30 GiB) to match the Starter
  plan's bundle. Some plans bundle a different fixed storage size — if the new
  plan's bundle differs, bump `os_disk_size` to match or `apply` will error. (This
  is only about the OS disk; app data is on the separate `data_disk_size` device,
  which you can grow independently.)
- **Zone availability.** Not every plan/shape is offered in every `zone` (the
  default `fi-hel1` is where the Starter plan lives). Moving to a plan the zone
  doesn't offer fails with an availability error.

### Growing the data device

Storage is independent of the compute plan. To give the app more disk (not more
CPU/RAM), raise [`data_disk_size`](infra/variables.tf) and `tofu apply`; then grow
the filesystem on the box to fill the enlarged device. Shrinking is not supported.

## Fresh-VM cutover

When a resize can't do it — changing `zone`, swapping the OS template, or
rebuilding a box from scratch — stand up a **new** VM and migrate the data to it.
This produces a **new IP**, so it **does** require cutting the registrar DNS.

The full runbook lives in the README under
**[Fresh-VM cutover](README.md#fresh-vm-cutover-from-the-existing-host)**: apply
the new VM, `rsync` the data across, `docker compose up -d`, verify, then point
DNS at the new IP and decommission the old VM.
