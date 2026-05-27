```
#                                                         
#     ▄▄▄▄ ▄▄  ▄▄  ▄▄▄  ▄▄▄▄  ▄▄▄▄  ▄▄▄▄▄  ▄▄▄▄ ▄▄▄▄▄▄ ▄▄▄  ▄▄▄▄  ▄▄▄▄▄ 
#    ███▄▄ ███▄██ ██▀██ ██▄█▀ ██▄█▄ ██▄▄  ███▄▄   ██  ██▀██ ██▄█▄ ██▄▄  
#    ▄▄██▀ ██ ▀██ ██▀██ ██    ██ ██ ██▄▄▄ ▄▄██▀   ██  ▀███▀ ██ ██ ██▄▄▄ 
#
#
```


# DigitalOcean Snapshot & Restore

Two bash scripts and an optional Slack bot for managing DigitalOcean droplet snapshots cost-effectively: snapshot and delete when idle, restore when needed, with the same reserved IP so DNS and Cloudflare configs stay valid.

**Cost model:** ~$0.06/GB/month for snapshot storage vs $12–48+/month for a running droplet.

## What's included

| Component | Purpose |
|-----------|---------|
| `do-snapshot.sh` | Snapshot a droplet; interactive shutdown confirmation; start/leave/delete after |
| `do-restore.sh` | Create a new droplet from a snapshot; reassign a reserved IP |
| `slack-bot/` | Slack slash commands to trigger snapshot and restore without SSH; interactive Block Kit confirmations; nginx welcome page on restore |

## Documentation

| Doc | When to read it |
|-----|----------------|
| [Setup guide](docs/setup.md) | First-time setup — covers everything start to finish |
| [Commands reference](docs/commands.md) | Day-to-day operations cheatsheet |
| [Troubleshooting](docs/troubleshooting.md) | When something goes wrong |
| [Architecture](docs/snaprestore-viz.md) | How the pieces connect — ASCII diagrams |
| [Slack integration options](docs/slack-integration-options.md) | Free controller alternatives, Slack connection modes |
| [Benchmarks](docs/benchmarks-speed-tests.md) | How to time snapshot/restore cycles; comparison vs alternatives |
| [Feature backlog](docs/PARKING_LOT.md) | Planned improvements |

---

## Requirements

| Tool | Required | Purpose |
|------|----------|---------|
| `doctl` | Yes | DigitalOcean CLI |
| `jq` | Yes | JSON parsing |
| `1password-cli` | Yes | Secure secret injection via `op read` / `op run` |
| `fzf` | Optional | Arrow-key selection menus (falls back to numbered lists) |
| `gum` | Optional | Rich TUI prompts |
| `uv` | Slack bot only | Python environment and dependency management |

Install all at once (macOS):

```bash
brew install doctl jq 1password-cli fzf gum && curl -LsSf https://astral.sh/uv/install.sh | sh
```

---

## Quick start (returning users)

**Bash scripts:**

```bash
./do-snapshot.sh --log snapshot.log
./do-restore.sh --log restore.log
```

**Slack bot** (once deployed):

```
/do-snapshot               → interactive: choose shutdown, then snapshot
/do-restore <snap-id>      → restore a snapshot; nginx welcome page installs on the new droplet
/do-deploy-cancel <job-id> → cancel a running job
```

See [docs/commands.md](docs/commands.md) for the full command reference including bot management.

---

## API token scopes

Create tokens at [cloud.digitalocean.com/account/api/tokens](https://cloud.digitalocean.com/account/api/tokens) with **Custom Scopes**.

Both the **scripts token** (`snaprestore-scripts`) and the **Slack bot token** (`snaprestore-bot`) need the same set:

| Scope | Required by |
|-------|-------------|
| `droplet:read` | Both scripts, bot |
| `droplet:create` | `do-restore.sh`, bot |
| `droplet:update` | `do-snapshot.sh`, bot — shutdown, power-off, snapshot action |
| `droplet:delete` | `do-snapshot.sh`, bot — delete after snapshot (optional) |
| `image:create` | Both — snapshot creation goes through the images API |
| `image:read` | Both — list and verify snapshots |
| `snapshot:read` | Both scripts, bot |
| `snapshot:delete` | `do-snapshot.sh`, bot — prune old snapshots |
| `ssh_key:read` | `do-restore.sh`, bot — attach SSH key at creation |
| `reserved_ip:read` | Both scripts, bot |
| `reserved_ip:update` | `do-restore.sh`, bot — assign reserved IP to restored droplet |
| `action:read` | `do-restore.sh`, bot — poll reserved IP assignment status |

> **Missing `image:create` or `droplet:create` are the most common setup mistakes.** Without `image:create` the snapshot call returns a silent 403. Without `droplet:create` the restore wizard completes normally but no droplet is created.

---

## Typical workflow

**Snapshot and shut down when idle:**
```bash
./do-snapshot.sh
# Select droplet → confirm shutdown → name snapshot → choose "delete"
# ~$0.06/GB/mo snapshot storage vs $12–48+/mo running droplet
```

**Restore when needed:**
```bash
./do-restore.sh
# Select snapshot → choose size → assign reserved IP
# Same IP, same DNS, same Cloudflare config
```

**Via Slack** (no SSH required):
```
/do-snapshot
# Bot asks: shut down before snapshotting? → Yes/No buttons
# After snapshot: restart droplet? → Yes/No buttons

/do-restore my-droplet-snapshot-20260527-0100
# Bot creates droplet, installs nginx welcome page via cloud-init,
# runs HTTP health check, posts IP and status to the thread
```

---

## File structure

```
snaprestore/
├── CLAUDE.md                 # Claude Code context — read this first in a new session
├── do-snapshot.sh
├── do-restore.sh
├── .env.example              # Variable reference with op:// path examples
├── docs/
│   ├── setup.md              # First-time setup guide (Parts 1–6)
│   ├── commands.md           # Day-to-day commands reference
│   ├── troubleshooting.md    # Organized by symptom
│   ├── snaprestore-viz.md    # Architecture diagrams
│   ├── slack-integration-options.md  # Free controller alternatives
│   ├── benchmarks-speed-tests.md     # Timing methodology and comparisons
│   └── PARKING_LOT.md        # Feature backlog
├── lib/
│   ├── bootstrap_sh.sh
│   ├── ui_sh.sh
│   └── ui_rich_py.py
├── slack-bot/
│   ├── bot.py                # Slack Bolt async app
│   ├── pyproject.toml        # Python dependencies
│   ├── manifest.yml          # Slack app manifest
│   ├── .env.op.example       # 1Password op:// reference template
│   ├── start.sh              # Startup wrapper (op run → uv run)
│   ├── README-slack-bot.md   # Slack bot setup and architecture detail
│   ├── systemd/
│   │   └── do-snap-bot.service
│   └── cloud-init/
│       └── controller.yml    # ⚠ Contains live secrets when edited — never commit
└── old_v1/                   # Original scripts preserved for reference
```

---

## License

MIT
