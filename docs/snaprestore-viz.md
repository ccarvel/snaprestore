# Snaprestore Architecture

## Local scripts

```
┌─────────────────────────────────────────────────────────────────────────┐
│                         LOCAL MACHINE                                   │
│                                                                         │
│  do-snapshot.sh ──┐                                                     │
│  do-restore.sh  ──┼──► doctl (context: snaprestore) ──► DO API         │
│                   │         ▲                                           │
│  1Password CLI ───┘   token stored in                                   │
│  (op read)            ~/.config/doctl/config.yaml                       │
│                       (never in scripts or env)                         │
└─────────────────────────────────────────────────────────────────────────┘
```

## Slack bot flow

```
┌─────────────────────────────────────────────────────────────────────────┐
│                         SLACK BOT FLOW                                  │
│                                                                         │
│  You ──► Slack ──► Slack API (WebSocket / Socket Mode)                  │
│                         │                                               │
│                         │  persistent outbound connection               │
│                         │  (no public inbound port needed)              │
│                         ▼                                               │
│              Controller Droplet  104.236.56.16                         │
│         ┌──────────────────────────────────────────┐                   │
│         │  systemd: do-snap-bot.service             │                   │
│         │                                           │                   │
│         │  EnvironmentFile: /etc/do-snap-bot/env    │                   │
│         │    └─ OP_SERVICE_ACCOUNT_TOKEN=ops_...    │                   │
│         │                                           │                   │
│         │  op run --env-file=.env.op                │                   │
│         │    resolves op://CDS_Vault/do-snap-bot/*  │                   │
│         │    injects: SLACK_BOT_TOKEN               │                   │
│         │             SLACK_APP_TOKEN               │                   │
│         │             SLACK_SIGNING_SECRET          │                   │
│         │             DIGITALOCEAN_ACCESS_TOKEN     │                   │
│         │             SLACK_ALLOWED_USERS           │                   │
│         │    └──► uv run bot.py                     │                   │
│         │              │                            │                   │
│         │              │  asyncio tasks per job     │                   │
│         │              │  Block Kit buttons         │                   │
│         │              │  asyncio.Event for         │                   │
│         │              │  button confirmations      │                   │
│         │              ▼                            │                   │
│         │         doctl (context: snaprestore)      │                   │
│         │              │                            │                   │
│         └──────────────┼────────────────────────────┘                   │
│                        ▼                                                │
│                    DigitalOcean API                                     │
│            droplet:read/create/update/delete                            │
│            snapshot:read/delete  image:create/read                      │
│            reserved_ip:read/update  ssh_key:read  action:read           │
│                        │                                                │
│              ┌─────────┴──────────┐                                     │
│              ▼                    ▼                                     │
│        Target Droplet      Reserved IP                                  │
│        (snapshotted /      (stays constant across                       │
│         restored)          destroy → restore cycles)                    │
│                            DNS + Cloudflare never change                │
└─────────────────────────────────────────────────────────────────────────┘
```

## Secret flow

```
┌─────────────────────────────────────────────────────────────────────────┐
│                         SECRET FLOW                                     │
│                                                                         │
│  1Password (CDS_Vault)                                                  │
│    ├─ do-snap-bot item ──► op run on controller ──► bot.py env vars     │
│    └─ DigitalOcean API Token snaprestore-scripts                        │
│         └──► op read on local machine ──► doctl init (one-time setup)  │
└─────────────────────────────────────────────────────────────────────────┘
```
