# Slack Integration Options

## Deleting a snapshot

```bash
# List snapshots to find the ID
doctl compute snapshot list --resource droplet

# Delete by ID
doctl compute snapshot delete <snapshot-id>

# Interactive one-liner with fzf
doctl compute snapshot list --resource droplet | fzf | awk '{print $1}' | xargs doctl compute snapshot delete
```

The `delete` command prompts for confirmation by default. Add `--force` to skip it in scripts.

A `/do-snapshot-delete` Slack command is a natural next addition — same pattern as the existing commands: list call to show options, confirmation buttons, then delete.

---

## How the two Slack connection modes work

| Mode | How it works | Needs public endpoint? |
|------|-------------|----------------------|
| **Socket Mode** (current) | Bot opens outbound WebSocket to Slack; Slack pushes events through it | No — outbound only |
| **Events API / HTTP** | Slack POSTs to your HTTPS URL when events fire | Yes — needs stable public URL |

Socket Mode is why the controller droplet works without a firewall rule or domain. Switching to HTTP mode makes serverless options viable, but requires a public HTTPS endpoint and a more complex job architecture for long-running operations.

---

## Free alternatives to the controller droplet

### Oracle Cloud Always Free — best drop-in replacement

- 2 AMD VMs (1 OCPU / 1 GB RAM each), permanently free
- Run the bot exactly as-is: same setup, same systemd unit, same `op run` invocation
- No architectural changes required
- Catch: Oracle's free tier sign-up occasionally gets flagged; YMMV on account approval

### Fly.io free tier

- 3 shared VMs (256 MB RAM), always on
- Deploy via Docker container or `fly deploy`; persistent enough for Socket Mode
- Slightly more setup than a raw VM but well-documented

### AWS Lambda + API Gateway

- Lambda free tier: 1M requests + 400K GB-seconds/month
- **The problem:** Lambda is stateless with a 15-minute max timeout. Snapshot jobs routinely run longer. To make it work you'd need to:
  - Switch from Socket Mode → HTTP Events API (requires API Gateway for a public HTTPS URL)
  - Restructure jobs: Lambda acks Slack immediately, then hands off to SQS or Step Functions for the long-running portion
- That's a significant rewrite and adds AWS service dependencies (Step Functions is not free-tier-friendly)
- **Verdict:** Technically doable but the effort is high and the result is more complex than the current droplet setup. Not worth it here.

### Local machine / home server

- Socket Mode means the bot can run anywhere with outbound internet — your Mac, a Raspberry Pi, a home server
- `uv run python bot.py` in a tmux session, or a launchd/systemd unit
- Free; zero cloud cost; only works when the machine is on

### Render / Railway

- Both can run a persistent Python process
- Render free tier sleeps after 15 min of inactivity, which kills the Socket Mode WebSocket connection — not viable
- Railway gives ~$5/month of free credit; at minimal memory usage the bot runs for months before hitting the cap

---

## Recommendation

**Oracle Cloud Always Free** is the cleanest path: identical setup to the current DigitalOcean controller, zero ongoing cost, no code changes. Sign up at [cloud.oracle.com](https://cloud.oracle.com) and provision an AMD VM in the always-free tier.

Second choice: run the bot locally on your Mac if 24/7 availability isn't required.
