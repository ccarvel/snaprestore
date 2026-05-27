# DigitalOcean Snapshot & Restore

Two bash scripts and an optional Slack bot for managing DigitalOcean droplet snapshots cost-effectively: snapshot and delete when idle, restore when needed, with the same reserved IP so DNS and Cloudflare configs stay valid.

## What's included

| Component | Purpose |
|-----------|---------|
| `do-snapshot.sh` | Snapshot a droplet; optionally shuts it down first; start/leave/delete after |
| `do-restore.sh` | Create a new droplet from a snapshot; reassign a reserved IP |
| `slack-bot/` | Slack slash commands to trigger snapshot and restore without SSH |

## Documentation

| Doc | When to read it |
|-----|----------------|
| [Setup guide](docs/setup.md) | First-time setup — covers everything start to finish |
| [Commands reference](docs/commands.md) | Day-to-day operations cheatsheet |
| [Troubleshooting](docs/troubleshooting.md) | When something goes wrong |

---

## Requirements

| Tool | Required | Purpose |
|------|----------|---------|
| `doctl` | Yes | DigitalOcean CLI |
| `jq` | Yes | JSON parsing |
| `1password-cli` | Yes | Secure secret injection via `op read` |
| `fzf` | Optional | Arrow-key selection menus (falls back to numbered lists) |
| `gum` | Optional | Rich TUI prompts |

Install all at once (macOS):

```bash
brew install doctl jq 1password-cli fzf gum
```

---

## Quick start (returning users)

```bash
# Snapshot a droplet
./do-snapshot.sh --log snapshot.log

# Restore from a snapshot
./do-restore.sh --log restore.log
```

See [docs/commands.md](docs/commands.md) for the full command reference including bot management.

---

## API token scopes

Create tokens at [cloud.digitalocean.com/account/api/tokens](https://cloud.digitalocean.com/account/api/tokens) with **Custom Scopes**.

**Scripts token** (`snaprestore-scripts`) — used by both scripts via the doctl context:

| Scope | Required by |
|-------|-------------|
| `droplet:read` | Both scripts |
| `droplet:create` | `do-restore.sh` |
| `droplet:update` | `do-snapshot.sh` — shutdown, power-off, snapshot action |
| `droplet:delete` | `do-snapshot.sh` — delete after snapshot (optional) |
| `image:create` | Both — snapshot creation goes through the images API |
| `snapshot:read` | Both scripts |
| `snapshot:delete` | `do-snapshot.sh` — prune old snapshots |
| `ssh_key:read` | `do-restore.sh` — attach SSH key at creation |
| `reserved_ip:read` | Both scripts |
| `reserved_ip:update` | `do-restore.sh` — assign reserved IP to restored droplet |
| `action:read` | `do-restore.sh` — poll reserved IP assignment status |

> **Missing `droplet:create` is the most common setup mistake.** Without it the restore wizard completes normally but no droplet is created and no error is shown.

**Slack bot token** (`snaprestore-bot`): same scope set as the scripts token.

---

## Typical workflow

**Snapshot and shut down when idle:**
```bash
./do-snapshot.sh
# Select droplet → confirm shutdown → name snapshot → choose "delete"
# ~$0.74/mo snapshot storage vs ~$24/mo running droplet
```

**Restore when needed:**
```bash
./do-restore.sh
# Select snapshot → choose size → assign reserved IP
# Same IP, same DNS, same Cloudflare config
```

---

## File structure

```
snaprestore/
├── do-snapshot.sh
├── do-restore.sh
├── .env.example              # Variable reference with op:// path examples
├── docs/
│   ├── setup.md              # First-time setup guide
│   ├── commands.md           # Day-to-day commands reference
│   └── troubleshooting.md    # Organized by symptom
├── lib/
│   ├── bootstrap_sh.sh
│   ├── ui_sh.sh
│   └── ui_rich_py.py
└── slack-bot/
    ├── bot.py
    ├── pyproject.toml
    ├── manifest.yml
    ├── .env.op.example
    ├── start.sh
    ├── README-slack-bot.md
    ├── systemd/
    │   └── do-snap-bot.service
    └── cloud-init/
        └── controller.yml
```

---

## License

MIT
