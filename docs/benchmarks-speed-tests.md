# Benchmarks & Speed Tests

How to measure snapshot creation and restore times, and how this approach compares to alternatives.

---

## What to measure

| Phase | Start | End |
|-------|-------|-----|
| Snapshot creation | `doctl` command issued / `/do-snapshot` triggered | `--wait` returns / bot reports complete |
| Droplet restore | `doctl create` issued / `/do-restore` triggered | Droplet status active, SSH port open |
| Network ready | Droplet active | HTTP health check passes (nginx up) |
| Full cycle (snapshot → destroy → restore → usable) | Snapshot start | nginx/HTTP responding |

---

## Timing via the shell scripts

Use `time` to wrap the full script run:

```bash
time ./do-snapshot.sh --log snapshot.log
time ./do-restore.sh --log restore.log
```

Parse the log file for individual phase timestamps:

```bash
# Snapshot start and end
grep -E "snapshot|complete|elapsed" snapshot.log

# Restore start, droplet active, health check
grep -E "Creating|active|health" restore.log
```

### One-liner: time just the doctl calls

```bash
# Time snapshot creation only (no prompts)
DROPLET_ID=<your-droplet-id>
SNAP_NAME="bench-$(date +%Y%m%d-%H%M%S)"

time doctl compute droplet-action snapshot "$DROPLET_ID" \
  --snapshot-name "$SNAP_NAME" --wait

# Time restore (droplet create from snapshot)
SNAP_ID=<snapshot-id>
time doctl compute droplet create bench-restore \
  --image "$SNAP_ID" \
  --size s-1vcpu-1gb \
  --region nyc3 \
  --wait
```

---

## Timing via the Slack bot

The bot already reports elapsed time for each phase in the thread:

- Snapshot: `✅ Snapshot complete! (MM:SS)`
- Restore: `✅ Droplet created! (MM:SS)`
- Health check: passes or times out after 5 min

No extra tooling needed — run `/do-snapshot` and `/do-restore` and read the timestamps in the thread.

---

## Benchmark log template

Copy this to a notes file and fill in after each test run:

```
Date:
Droplet:          name / size / region
Disk allocated:   GB
Disk used:        GB  (df -h / — the number that matters for snapshot size)

--- Snapshot ---
Start:
End:
Elapsed:
Snapshot size:    GB
Est. monthly cost: $

--- Restore ---
Snapshot used:
Start:
Droplet active:
SSH ready:
HTTP (nginx) up:
Total elapsed:
```

---

## Typical timing ranges

These vary by region load and actual disk usage (not allocated disk):

| Disk used | Snapshot creation | Droplet create + boot | HTTP ready |
|-----------|------------------|-----------------------|------------|
| ~5 GB | 2–4 min | 60–90 sec | +30–60 sec |
| ~20 GB | 5–10 min | 60–90 sec | +30–60 sec |
| ~50 GB | 12–20 min | 60–90 sec | +30–60 sec |
| ~80 GB | 18–30 min | 60–90 sec | +30–60 sec |

Droplet creation time is roughly constant regardless of snapshot size — the image is already in DO's storage, the boot itself is what takes 60–90 sec.

**Key insight:** minimize disk usage on the source droplet to minimize snapshot time. `df -h /` is the number that matters, not the allocated disk size.

---

## Is this the fastest on-demand server method?

For a general-purpose Ubuntu droplet: **yes, for the restore half.** Droplet creation from a snapshot is ~60–90 seconds to active, which is roughly the floor for any cloud VM (AWS EC2, GCP Compute Engine, Azure VM all land in the same range).

The snapshot creation half is where time varies — it depends on how much data is on disk.

### Comparison

| Method | Cold start time | Monthly cost (idle) | Notes |
|--------|----------------|--------------------|----|
| **Snapshot → restore (this workflow)** | 3–20 min total | ~$0.06/GB/mo snapshot storage | Slowest to start, cheapest at rest |
| Keep droplet running | Instant | $12–48+/mo | Fastest, most expensive |
| DO Reserved snapshot + restore | Same as above | Same | This is what this workflow does |
| AWS EC2 AMI → instance | 3–8 min | ~$0.05/GB/mo EBS snapshot | Equivalent; EC2 restores slightly faster at scale |
| Docker container (pre-built image) | 10–30 sec | Image registry storage only | Fastest cold start but requires containerized workload |
| DO App Platform / managed | Near-instant scale | Starts at ~$5/mo + usage | Only works for supported stacks (Node, Python, etc.) |
| Kubernetes (DO DOKS) | 30–60 sec per pod | $12+/mo for control plane | Overkill for single-server use cases |

### When to use each

- **This workflow** — single server that runs infrequently (hours/week), arbitrary Ubuntu workloads, DNS/IP must stay stable
- **Keep it running** — server needed most of the time; cost savings don't justify the restore time
- **Containers** — stateless workloads, easy to rebuild, no bare-metal requirements
- **App Platform** — simple web apps where you don't need root access

---

## Tips to minimize restore time

1. **Keep disk usage small.** Delete logs, caches, and build artifacts before snapshotting. Run `du -sh /* | sort -h` to find large directories.
2. **Use a nearby region.** Restore from a snapshot in the same region as your reserved IP to avoid cross-region transfer.
3. **Keep the snapshot recent.** Old snapshots still restore at the same speed, but you'll spend more time after restore applying updates.
4. **Use the smallest adequate droplet size.** `s-1vcpu-1gb` ($6/mo) restores in the same time as a larger size. Resize up after if needed via `doctl compute droplet-action resize`.
5. **Pre-warm.** If you know you'll need the server in 30 min, start the restore now rather than waiting until you need it.
