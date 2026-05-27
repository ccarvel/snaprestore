# Parking Lot

Planned features and improvements, roughly in priority order within each section.

---

## Parity

- [ ] **Parity:** Add nginx welcome page feature to bash scripts (`do-restore.sh`) — pass `--user-data-file` with the cloud-init YAML at droplet create time, matching the Slack bot behavior

- [ ] **Feature: Auto-start Docker containers on restore** — when a droplet is restored from a snapshot, any Docker Compose stacks that were stopped at snapshot time will not restart automatically (Docker's restart policy only fires on daemon restart, not from a stopped state in a snapshot image).

  **Operator note (do this now, in your compose files):**
  - Make sure every service in every `docker-compose.yml` has `restart: unless-stopped` (or `restart: always`). This handles reboots and daemon restarts for free — no extra tooling required.

  **Implementation note (for a future session):**
  - The restore flow in both `do-restore.sh` and `bot.py` already passes a `--user-data-file` (cloud-init YAML) at droplet create time. Extend that YAML to include a `runcmd` section that runs `docker compose up -d` in the relevant directories on first boot.
  - Example cloud-init addition:
    ```yaml
    runcmd:
      - cd /opt/myapp && docker compose up -d
      - cd /opt/otherapp && docker compose up -d
    ```
  - For `do-restore.sh`: add a `--compose-dir PATH` flag (repeatable) that appends `runcmd` entries to the generated user-data file.
  - For `bot.py`: read a `DOCKER_COMPOSE_DIRS` env var (comma-separated paths, set in `.env.op` on the controller) and inject those paths as `runcmd` entries in `build_welcome_cloud_init()`. The env var acts as the default; a future `/do-restore` arg could override it per-restore.
  - Cloud-init `runcmd` runs once at first boot, after networking is up — the right time to bring stacks online.

---

## Slack commands

- [x] **Feature:** `/do-snapshot-delete <id-or-name>` — list snapshots with confirmation buttons, then delete the selected one

- [x] **Feature:** `/do-droplet-create <name> <size> <image>` — create a new droplet from a snapshot or base image; prompt for missing args interactively

- [x] **Feature:** `/do-droplet-list` — list all droplets with name, status, size, region, and public IP

- [x] **Feature:** `/do-droplet-power-on <name-or-id>` — power on a stopped droplet (faster than a full restore when the droplet still exists)

- [x] **Feature:** `/do-droplet-power-off <name-or-id>` — graceful shutdown with fallback to power-off, with confirmation button

- [x] **Feature:** `/do-droplet-delete <name-or-id>` — delete a droplet with a confirmation button; warn if it has no recent snapshot

- [x] **Feature:** `/do-droplet-resize <name-or-id> <size>` — resize a droplet to a new slug (e.g. `s-2vcpu-2gb`); requires power-off first, bot handles it

- [x] **Feature:** `/do-reserved-ip-assign <ip> <droplet-name-or-id>` — manually reassign a reserved IP to a running droplet (useful after a restore that skipped IP assignment)

- [x] **Feature:** `/do-snapshot-list` — list recent snapshots with name, size, region, age, and estimated monthly cost

---

## Bot improvements

- [x] `/do-restore` interactive flow — currently requires snapshot ID/name as an argument; add button-based selection from a list (same pattern as snapshot shutdown confirmation)

- [x] Scheduled snapshots — cron-style support so the bot can auto-snapshot on a schedule and post a confirmation to Slack when done

- [x] Snapshot retention policy — after creating a new snapshot, automatically delete snapshots older than N days or beyond the N most recent, with a Slack summary of what was pruned
