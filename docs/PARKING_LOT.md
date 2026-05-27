# Parking Lot

Planned features and improvements, roughly in priority order within each section.

---

## Parity

- [ ] **Parity:** Add nginx welcome page feature to bash scripts (`do-restore.sh`) — pass `--user-data-file` with the cloud-init YAML at droplet create time, matching the Slack bot behavior

---

## Slack commands

- [ ] **Feature:** `/do-snapshot-delete <id-or-name>` — list snapshots with confirmation buttons, then delete the selected one

- [ ] **Feature:** `/do-droplet-create <name> <size> <image>` — create a new droplet from a snapshot or base image; prompt for missing args interactively

- [ ] **Feature:** `/do-droplet-list` — list all droplets with name, status, size, region, and public IP

- [ ] **Feature:** `/do-droplet-power-on <name-or-id>` — power on a stopped droplet (faster than a full restore when the droplet still exists)

- [ ] **Feature:** `/do-droplet-power-off <name-or-id>` — graceful shutdown with fallback to power-off, with confirmation button

- [ ] **Feature:** `/do-droplet-delete <name-or-id>` — delete a droplet with a confirmation button; warn if it has no recent snapshot

- [ ] **Feature:** `/do-droplet-resize <name-or-id> <size>` — resize a droplet to a new slug (e.g. `s-2vcpu-2gb`); requires power-off first, bot handles it

- [ ] **Feature:** `/do-reserved-ip-assign <ip> <droplet-name-or-id>` — manually reassign a reserved IP to a running droplet (useful after a restore that skipped IP assignment)

- [ ] **Feature:** `/do-snapshot-list` — list recent snapshots with name, size, region, age, and estimated monthly cost

---

## Bot improvements

- [ ] `/do-restore` interactive flow — currently requires snapshot ID/name as an argument; add button-based selection from a list (same pattern as snapshot shutdown confirmation)

- [ ] Scheduled snapshots — cron-style support so the bot can auto-snapshot on a schedule and post a confirmation to Slack when done

- [ ] Snapshot retention policy — after creating a new snapshot, automatically delete snapshots older than N days or beyond the N most recent, with a Slack summary of what was pruned
