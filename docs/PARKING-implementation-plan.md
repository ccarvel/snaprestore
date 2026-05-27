# SnapRestore Bot — Implementation Plan
## Scope: Slack Commands & Bot Improvements from `docs/PARKING_LOT.md`

This plan covers **only** the items under the **Slack commands** and **Bot improvements** sections of `docs/PARKING_LOT.md`. No other parking lot sections are addressed.

---

## 1. Title and Scope

**Goal:** Implement the nine new slash commands and three bot improvements listed in `docs/PARKING_LOT.md` §Slack commands and §Bot improvements.

**Out of scope:** The §Parity item (nginx welcome page in `do-restore.sh`) is explicitly excluded.

---

## 2. Repository Understanding

### Architecture

```
Slack ──► Socket Mode WebSocket ──► slack-bot/bot.py ──► doctl subprocess ──► DO API
```

- **Language/runtime:** Python 3.11+, managed by `uv`. Single file: `slack-bot/bot.py` (773 lines).
- **Framework:** `slack-bolt>=1.19` async (`AsyncApp`) in Socket Mode. No HTTP ingress required.
- **Secret injection:** `op run --env-file=.env.op` at startup. Secrets never touch disk.
- **Deployment:** systemd service (`do-snap-bot.service`) on a dedicated $6/mo DigitalOcean controller droplet at `104.236.56.16`, user `dosnap`, working dir `/opt/do-snap-bot`.

### Existing Slack Bot Structure

| Element | Location | Notes |
|---------|----------|-------|
| App init | `bot.py:33–36` | `AsyncApp(token=..., signing_secret=...)` |
| Command handlers | `bot.py:273–761` | Three `@app.command()` handlers |
| Action handlers | `bot.py:297–354` | Five `@app.action()` handlers (button callbacks) |
| Job coroutines | `bot.py:357–733` | `_snapshot_job`, `_restore_job` |
| doctl wrappers | `bot.py:58–122` | `run_doctl()`, `run_doctl_long()` |
| DO query helpers | `bot.py:179–200` | `list_droplets()`, `list_snapshots()`, `get_droplet()` |
| Confirmation pattern | `bot.py:205–268` | `_ask_confirmation()`, `PENDING_CONFIRMATIONS`, `_resolve_confirmation()` |
| Cancel sentinel | `bot.py:44–49` | `JOBS_DIR`, `_cancel_path()`, `_is_cancelled()` |
| Auth | `bot.py:52–55` | `_authorize()` — gates on `SLACK_ALLOWED_USERS` env var |

### Coding Conventions

1. Every command calls `await ack()` immediately, then posts an initial thread-anchoring message, then dispatches `asyncio.create_task(_<name>_job(...))`.
2. All subsequent updates go to `thread_ts` via `client.chat_postMessage(channel=..., thread_ts=..., text=...)`.
3. Interactive buttons use `_ask_confirmation()` + `PENDING_CONFIRMATIONS` + a matching `@app.action()` handler pair per confirmation type. Action IDs are descriptive snake_case strings.
4. Long `doctl` calls use `run_doctl_long()`. Quick reads use `run_doctl()`.
5. Every job coroutine wraps its body in `try/except Exception` and posts the traceback to the thread.
6. Every command checks `_authorize(user_id)` before doing anything; unauthorized → `chat_postEphemeral`.
7. Every `run_doctl_long()` call checks `_is_cancelled(job_id)` between heartbeats.
8. **Manifest bug:** `manifest.yml` currently has `interactivity.is_enabled: false` despite Block Kit buttons being in active use. This must be corrected to `true`.
9. No tests exist — plan adds a minimal pytest file.
10. No new dependencies may be added.

---

## 3. Relevant PARKING_LOT Items

### Slack Commands

1. `/do-snapshot-delete <id-or-name>` — list snapshots with confirmation buttons, then delete the selected one
2. `/do-droplet-create <name> <size> <image>` — create a new droplet from a snapshot or base image; prompt for missing args interactively
3. `/do-droplet-list` — list all droplets with name, status, size, region, and public IP
4. `/do-droplet-power-on <name-or-id>` — power on a stopped droplet
5. `/do-droplet-power-off <name-or-id>` — graceful shutdown with fallback to power-off, with confirmation button
6. `/do-droplet-delete <name-or-id>` — delete a droplet with a confirmation button; warn if it has no recent snapshot
7. `/do-droplet-resize <name-or-id> <size>` — resize a droplet to a new slug; requires power-off first, bot handles it
8. `/do-reserved-ip-assign <ip> <droplet-name-or-id>` — manually reassign a reserved IP to a running droplet
9. `/do-snapshot-list` — list recent snapshots with name, size, region, age, and estimated monthly cost

### Bot Improvements

1. `/do-restore` interactive flow — add button-based selection from a list (same pattern as snapshot shutdown confirmation)
2. Scheduled snapshots — cron-style support so the bot can auto-snapshot on a schedule and post a confirmation to Slack when done
3. Snapshot retention policy — after creating a new snapshot, automatically delete snapshots older than N days or beyond the N most recent, with a Slack summary of what was pruned

---

## 4. Gap Analysis

### What Already Exists

| Feature | File | Notes |
|---------|------|-------|
| `/do-snapshot` with confirmation buttons | `bot.py:273–561` | Full flow: shutdown + snapshot + restart prompts |
| `/do-restore <snap-id>` | `bot.py:566–733` | Works but requires argument; lists snapshots as text if omitted |
| `/do-deploy-cancel <job-id>` | `bot.py:738–761` | Sentinel-file cancel |
| `list_droplets()` | `bot.py:179–183` | Returns parsed JSON list |
| `list_snapshots()` | `bot.py:186–191` | Returns droplet snapshots |
| `get_droplet()` | `bot.py:194–200` | Single-droplet lookup |
| `_ask_confirmation()` pattern | `bot.py:205–259` | Generic binary yes/no buttons |
| `run_doctl()` / `run_doctl_long()` | `bot.py:58–122` | Reusable subprocess helpers |
| `_authorize()` | `bot.py:52–55` | All new commands must call this |
| Auth scopes | `manifest.yml:27–30` | `chat:write`, `chat:write.public`, `commands`, `users:read` |

### What Is Missing

- All 9 new slash commands (no handlers, no manifest entries)
- `interactivity.is_enabled: true` in `manifest.yml` (current value is `false` — a bug)
- `list_reserved_ips()` doctl helper
- `list_ssh_keys()` doctl helper (needed for `/do-droplet-create`)
- `delete_snapshot()` doctl helper (needed for retention + `/do-snapshot-delete`)
- `delete_droplet()` doctl helper (needed for `/do-droplet-delete`)
- Multi-option selection via Block Kit (a `_ask_selection()` helper for >2 choices)
- Snapshot retention pruning logic (`_prune_snapshots()`)
- Scheduled snapshot background loop
- `SNAPSHOT_SCHEDULE_INTERVAL_HOURS`, `SNAPSHOT_SCHEDULE_CHANNEL`, `SNAPSHOT_SCHEDULE_DROPLET`, `SNAPSHOT_RETENTION_DAYS`, `SNAPSHOT_RETENTION_COUNT` env vars

### What Is Partially Implemented

- `/do-restore` interactive selection: already lists snapshots as text when no argument given; needs upgrading to Block Kit buttons
- SSH key attachment: bash scripts handle it; `bot.py` currently does not pass `--ssh-keys` to `doctl compute droplet create`
- Size hint: hardcoded to `s-1vcpu-1gb` in `_restore_job()` (`bot.py:654`)

### Technical Constraints and Dependencies

1. **`manifest.yml` must be re-applied** to the Slack app at `api.slack.com` after each new command.
2. **Block Kit button limit:** Slack actions blocks allow a maximum of 5 button elements. Lists with more than 5 items fall back to text with re-run-with-ID instructions (matching existing pattern).
3. **Socket Mode + interactivity:** `interactivity.is_enabled: true` works with Socket Mode without a `request_url`.
4. **`asyncio.create_task()` without reference capture** is the existing pattern and will be continued.
5. **No test runner configured.** Minimal `pytest` file will be added.

### Risks and Open Questions

- Reserved IP JSON field names from `doctl` — to be verified against live account before implementation.
- SSH key selection when multiple keys exist — assumed: use first key (see Open Questions).
- Retention "more aggressive wins" semantics when both `DAYS` and `COUNT` are set (see Open Questions).

---

## 5. Implementation Strategy

### Proposed Order of Work

1. Fix manifest bug (`interactivity.is_enabled: false` → `true`)
2. Read-only commands: `/do-snapshot-list`, `/do-droplet-list`
3. Simple action commands: `/do-droplet-power-on`, `/do-droplet-power-off`
4. Destructive with confirmation: `/do-snapshot-delete`, `/do-droplet-delete`
5. Bot improvement #1: `/do-restore` button-based selection
6. Multi-step: `/do-droplet-resize`
7. Complex creation: `/do-droplet-create`
8. IP management: `/do-reserved-ip-assign`
9. Bot improvement #3: Snapshot retention policy
10. Bot improvement #2: Scheduled snapshots
11. Update `docs/commands.md` and `README-slack-bot.md`
12. Add minimal pytest tests

### Why This Order

- Read-only first — zero risk, validates new command registration pattern end-to-end.
- Destructive commands after read-only — allows independent testing of list helpers.
- `/do-restore` upgrade before `/do-droplet-create` — both use snapshot selection; the upgrade establishes `_ask_selection()` pattern first.
- Retention before scheduling — scheduler calls retention; retention must exist first.

### Regression Minimization

- Every new command uses the same `ack()` → thread-anchor → `create_task()` structure.
- All new `@app.action()` handlers use unique action IDs namespaced by command.
- `PENDING_CONFIRMATIONS` entries are keyed by unique `conf_id` — no cross-contamination possible.
- No existing handlers modified until step 5 (restore upgrade), confined to `_restore_job()`.

---

## 6. File-by-File Change Plan

| File | Action | Reason |
|------|--------|--------|
| `slack-bot/bot.py` | **UPDATE** | All new command handlers, action handlers, job coroutines, and helpers |
| `slack-bot/manifest.yml` | **UPDATE** | Fix `interactivity.is_enabled`, add 9 new slash commands |
| `slack-bot/.env.op.example` | **UPDATE** | Add scheduling and retention env var templates |
| `docs/PARKING-implementation-plan.md` | **CREATE** | This document |
| `docs/commands.md` | **UPDATE** | Add all new Slack commands to the reference table |
| `slack-bot/README-slack-bot.md` | **UPDATE** | Add new commands to Slash Commands table; add env vars to Variables Reference |
| `slack-bot/tests/test_bot.py` | **CREATE** | Minimal pytest unit tests |
| `pyproject.toml` | **NO CHANGE** | No new dependencies |
| `slack-bot/start.sh` | **NO CHANGE** | No startup changes |
| `slack-bot/systemd/do-snap-bot.service` | **NO CHANGE** | Infrastructure unchanged |
| `slack-bot/cloud-init/controller.yml` | **NO CHANGE** | Infrastructure unchanged |
| `do-snapshot.sh` | **NO CHANGE** | Out of scope |
| `do-restore.sh` | **NO CHANGE** | Out of scope |

---

## 7. Slack Commands Plan

### Manifest Fix

```yaml
# BEFORE (bug):
settings:
  interactivity:
    is_enabled: false

# AFTER:
settings:
  interactivity:
    is_enabled: true
```

In Socket Mode, no `request_url` is required. The field is omitted.

### New Manifest Command Entries (9 total)

```yaml
- command: /do-snapshot-list
  description: List recent droplet snapshots with size, age, and cost
  usage_hint: ""
  should_escape: false

- command: /do-snapshot-delete
  description: Delete a snapshot (with confirmation)
  usage_hint: "[snapshot-id-or-name]"
  should_escape: false

- command: /do-droplet-list
  description: List all droplets with name, status, size, region, and IP
  usage_hint: ""
  should_escape: false

- command: /do-droplet-create
  description: Create a droplet from a snapshot or base image
  usage_hint: "<name> [size] [image]"
  should_escape: false

- command: /do-droplet-power-on
  description: Power on a stopped droplet
  usage_hint: "<name-or-id>"
  should_escape: false

- command: /do-droplet-power-off
  description: Graceful shutdown of a droplet (with confirmation)
  usage_hint: "<name-or-id>"
  should_escape: false

- command: /do-droplet-delete
  description: Delete a droplet (with confirmation; warns if no recent snapshot)
  usage_hint: "<name-or-id>"
  should_escape: false

- command: /do-droplet-resize
  description: Resize a droplet to a new size slug (powers off first)
  usage_hint: "<name-or-id> <size-slug>"
  should_escape: false

- command: /do-reserved-ip-assign
  description: Reassign a reserved IP to a droplet
  usage_hint: "<ip> <droplet-name-or-id>"
  should_escape: false
```

---

### New Shared Infrastructure (bot.py additions)

**New helpers:**

```python
async def delete_snapshot(snap_id: str) -> tuple[int, str, str]:
    return await run_doctl("compute", "snapshot", "delete", snap_id, "--force")

async def delete_droplet(droplet_id: str) -> tuple[int, str, str]:
    return await run_doctl("compute", "droplet", "delete", droplet_id, "--force")

async def list_ssh_keys() -> list[dict]:
    rc, out, _ = await run_doctl("compute", "ssh-key", "list", "--output", "json")
    if rc != 0 or not out:
        return []
    return json.loads(out)

async def list_reserved_ips() -> list[dict]:
    rc, out, _ = await run_doctl("compute", "reserved-ip", "list", "--output", "json")
    if rc != 0 or not out:
        return []
    return json.loads(out)
```

**New `_ask_selection()` helper** (extends `PENDING_CONFIRMATIONS` pattern for multi-choice):

```python
async def _ask_selection(
    client,
    channel: str,
    thread_ts: str,
    conf_id: str,
    question: str,
    options: list[tuple[str, str]],  # (label, value) up to 5
    timeout: int = 120,
) -> str | None:
    """Post up to 5 labeled buttons and wait for user selection.
    Returns the selected value or None on timeout.
    """
    event = asyncio.Event()
    PENDING_CONFIRMATIONS[conf_id] = {"event": event, "value": None}

    buttons = [
        {
            "type": "button",
            "text": {"type": "plain_text", "text": label},
            "action_id": "selection_pick",
            "value": f"{conf_id}:{value}",
        }
        for label, value in options[:5]
    ]
    await client.chat_postMessage(
        channel=channel,
        thread_ts=thread_ts,
        blocks=[
            {"type": "section", "text": {"type": "mrkdwn", "text": question}},
            {"type": "actions", "elements": buttons},
        ],
        text=question,
    )
    try:
        await asyncio.wait_for(event.wait(), timeout=timeout)
        raw = PENDING_CONFIRMATIONS.pop(conf_id, {}).get("value")
        if raw and ":" in raw:
            return raw.split(":", 1)[1]
        return raw
    except asyncio.TimeoutError:
        PENDING_CONFIRMATIONS.pop(conf_id, None)
        return None
```

**New `@app.action("selection_pick")` handler** (shared across all selection-type buttons):

```python
@app.action("selection_pick")
async def action_selection_pick(ack, body, client):
    await ack()
    raw_value = body["actions"][0]["value"]
    conf_id = raw_value.split(":", 1)[0]
    entry = PENDING_CONFIRMATIONS.get(conf_id)
    if entry:
        entry["value"] = raw_value  # full "conf_id:selected_value"
        entry["event"].set()
    await client.chat_update(
        channel=body["channel"]["id"],
        ts=body["message"]["ts"],
        blocks=[{
            "type": "section",
            "text": {"type": "mrkdwn", "text": f"✅ Selected."},
        }],
        text="Selected.",
    )
```

---

### Command Specifications

#### `/do-snapshot-list`
- **Handler:** `cmd_snapshot_list` — inline, no background job
- **Flow:** `ack()` → `list_snapshots()` → format mrkdwn (name, ID, size GB, region, age in days, est. cost) → `chat_postMessage`
- **Error:** "No snapshots found." if empty
- **No new action handlers needed**

#### `/do-droplet-list`
- **Handler:** `cmd_droplet_list` — inline
- **Flow:** `ack()` → `list_droplets()` → format mrkdwn (status emoji, name, ID, size, region, IP) → `chat_postMessage`
- **Status emoji:** 🟢 active, 🔴 off, 🟡 other

#### `/do-snapshot-delete [id-or-name]`
- **Handler:** `cmd_snapshot_delete` → `asyncio.create_task(_snapshot_delete_job(...))`
- **New action handlers:** `snapshot_delete_confirm_yes`, `snapshot_delete_confirm_no`
- **Flow:**
  1. `ack()` → post thread anchor
  2. If argument: lookup snapshot by ID/name from `list_snapshots()`
  3. If no argument: use `_ask_selection()` with up to 5 recent snapshots (label=name, value=snap_id)
  4. `_ask_confirmation()` — "*Delete `{name}` ({size} GB)?* This cannot be undone."
  5. On yes: `delete_snapshot(snap_id)` → post result
- **doctl scope required:** `snapshot:delete` (already in README)

#### `/do-droplet-power-on <name-or-id>`
- **Handler:** `cmd_droplet_power_on` → `asyncio.create_task(_droplet_power_on_job(...))`
- **Flow:**
  1. `ack()` → post thread anchor
  2. Resolve droplet via `list_droplets()`; if not found, post error
  3. If status == `active`: post "Already running" → return
  4. `run_doctl_long(...)` with `compute droplet-action power-on <id> --wait`
  5. Post result
- **No confirmation needed** (power-on is non-destructive)

#### `/do-droplet-power-off <name-or-id>`
- **Handler:** `cmd_droplet_power_off` → `asyncio.create_task(_droplet_power_off_job(...))`
- **New action handlers:** `droplet_poweroff_confirm_yes`, `droplet_poweroff_confirm_no`
- **Flow:**
  1. `ack()` → post thread anchor
  2. Resolve droplet; if already off, post "Already stopped" → return
  3. `_ask_confirmation()` — "Shut down `{name}`?"
  4. On yes: `doctl compute droplet-action shutdown <id> --wait`; on failure: `doctl compute droplet-action power-off <id> --wait` (same fallback pattern as `_snapshot_job`)
  5. Post result

#### `/do-droplet-delete <name-or-id>`
- **Handler:** `cmd_droplet_delete` → `asyncio.create_task(_droplet_delete_job(...))`
- **New action handlers:** `droplet_delete_confirm_yes`, `droplet_delete_confirm_no`
- **Flow:**
  1. `ack()` → post thread anchor
  2. Resolve droplet
  3. Check `list_snapshots()` for `{droplet_name}-snapshot-*` with `created_at` within last 7 days
  4. If no recent snapshot: prepend ⚠️ warning to confirmation message
  5. `_ask_confirmation()` — "Delete droplet `{name}`? This cannot be undone."
  6. On yes: `delete_droplet(droplet_id)` → post result
- **doctl scope required:** `droplet:delete` (already required)

#### `/do-droplet-resize <name-or-id> <size>`
- **Handler:** `cmd_droplet_resize` → `asyncio.create_task(_droplet_resize_job(...))`
- **New action handlers:** `droplet_resize_poweroff_yes`, `droplet_resize_poweroff_no`, `droplet_resize_poweron_yes`, `droplet_resize_poweron_no`
- **Flow:**
  1. `ack()` → validate both args (ephemeral error if missing) → post thread anchor
  2. Resolve droplet
  3. `_ask_confirmation()` — "Resize `{name}` to `{size}`? Requires power-off."
  4. On yes: shutdown with graceful→power-off fallback
  5. `run_doctl_long(...)` with `compute droplet-action resize <id> --size <size> --wait`
  6. Post result; offer power-on via `_ask_confirmation()`

#### `/do-droplet-create <name> [size] [image]`
- **Handler:** `cmd_droplet_create` → `asyncio.create_task(_droplet_create_job(...))`
- **Flow:**
  1. `ack()` → parse args → post thread anchor
  2. If `image` missing: use `_ask_selection()` with up to 5 recent snapshots
  3. `size` defaults to `s-1vcpu-1gb` if omitted
  4. `list_ssh_keys()` → use first key ID
  5. `build_welcome_cloud_init()` → temp file (same as `_restore_job`)
  6. `run_doctl_long(...)` with `compute droplet create <name> --image <id> --size <size> --region <region> --ssh-keys <key-id> --user-data-file <tmp> --wait --output json`
  7. Health check → post result (same as `_restore_job`)
- **New helper:** `list_ssh_keys()`

#### `/do-reserved-ip-assign <ip> <droplet-name-or-id>`
- **Handler:** `cmd_reserved_ip_assign` → inline
- **Flow:**
  1. `ack()` → validate both args (ephemeral error if missing)
  2. Resolve droplet ID via `list_droplets()`
  3. Validate IP via `list_reserved_ips()`
  4. `run_doctl("compute", "reserved-ip-action", "assign", ip, str(droplet_id))`
  5. Post result
- **New helper:** `list_reserved_ips()`

---

### Request/Response Flow (All Commands)

```
User types command in Slack
    │
    ▼
Bolt receives event via Socket Mode WebSocket
    │
    ▼
@app.command handler: await ack()   ← must complete within 3 seconds
    │
    ▼
Post initial thread-anchoring message, capture thread_ts
    │
    ▼
asyncio.create_task(_xxx_job(...))  ← non-blocking
    │
    ▼ (background task)
doctl subprocess calls + Slack thread updates
    │
    ▼
Final result posted to thread_ts
```

---

## 8. Bot Improvements Plan

### Improvement 1: `/do-restore` Interactive Button Selection

**Current behavior (`bot.py:611–626`):** If no `snap_hint`, the job posts a text list of up to 10 recent snapshots and returns. User must re-run with an ID.

**Target behavior:** Post up to 5 most recent snapshots as Block Kit buttons. User clicks one; the job proceeds.

**Engineering tasks:**

1. Replace the text-listing-and-return block (`bot.py:611–626`) in `_restore_job()` with a call to `_ask_selection()`.
2. `_ask_selection()` posts buttons; `@app.action("selection_pick")` resolves the choice.
3. If more than 5 snapshots exist, show the 5 newest and add a note: "Showing 5 most recent. Use `/do-restore <id>` for others."
4. Preserve existing behavior when `snap_hint` is provided (direct lookup, no buttons).

**Files modified:** `bot.py` only (lines ~611–626 replaced; `_ask_selection()` and `@app.action("selection_pick")` added as shared infrastructure used by other new commands too)

---

### Improvement 2: Scheduled Snapshots

**Target behavior:** Auto-snapshot on a configurable interval (in hours); post result to a configured Slack channel.

**Engineering tasks:**

1. Read env vars:
   - `SNAPSHOT_SCHEDULE_INTERVAL_HOURS` — float (e.g., `24`). If missing or `0`, scheduling disabled.
   - `SNAPSHOT_SCHEDULE_CHANNEL` — Slack channel ID. Required when scheduling enabled.
   - `SNAPSHOT_SCHEDULE_DROPLET` — droplet name or ID. If missing and only one droplet exists, use it; otherwise post warning and skip.
2. In `main()`, start `asyncio.create_task(_scheduled_snapshot_loop(...))` if `SNAPSHOT_SCHEDULE_INTERVAL_HOURS` is set.
3. `_scheduled_snapshot_loop()`:
   ```
   while True:
       await asyncio.sleep(interval_seconds)
       post initial message to SNAPSHOT_SCHEDULE_CHANNEL
       run _snapshot_job logic (reuse existing code, no interactive confirmations)
       if RETENTION configured: call _prune_snapshots()
   ```
4. Scheduled runs skip interactive prompts (no shutdown confirmation, no restart confirmation — snapshot taken live).
5. Add env vars to `.env.op.example`.

**Assumption:** "Cron-style" = fixed interval (every N hours) via `asyncio.sleep()`. A full cron parser is not warranted and would add a dependency.

---

### Improvement 3: Snapshot Retention Policy

**Target behavior:** After each snapshot, delete snapshots for the same droplet that are older than N days or beyond the N most recent.

**Engineering tasks:**

1. New helper `delete_snapshot(snap_id)` (also used by `/do-snapshot-delete`).
2. New function `_prune_snapshots(droplet_name, client, channel, thread_ts)`:
   - Calls `list_snapshots()`
   - Filters to snapshots matching `{droplet_name}-snapshot-*`
   - Applies configured retention rules
   - Deletes via `delete_snapshot()`
   - Posts pruning summary to thread
3. Call `_prune_snapshots()` at end of `_snapshot_job()` if `SNAPSHOT_RETENTION_DAYS` or `SNAPSHOT_RETENTION_COUNT` is set.
4. New env vars:
   - `SNAPSHOT_RETENTION_DAYS` — delete snapshots older than N days
   - `SNAPSHOT_RETENTION_COUNT` — keep only N most recent per droplet
5. If both set: more aggressive rule wins (a snapshot is pruned if it fails either rule).

---

## 9. Testing and Validation

### New Test File: `slack-bot/tests/test_bot.py`

Minimal `pytest` tests with mocked `run_doctl`:

```python
# Tests to implement:
# - test_list_snapshots_empty()        — run_doctl returns rc=0, out=""
# - test_list_snapshots_ok()           — run_doctl returns rc=0, out=JSON list
# - test_list_droplets_ok()
# - test_prune_snapshots_by_count()    — 5 snapshots, retain 3, verify 2 deleted
# - test_prune_snapshots_by_days()     — 2 old snapshots, verify both deleted
# - test_authorize_allow_all()         — SLACK_ALLOWED_USERS="" → True for any user
# - test_authorize_allow_list()        — only listed users pass
# - test_delete_snapshot_called()      — verify correct doctl args
```

### Manifest Validation

```bash
# Paste updated manifest.yml into:
# https://api.slack.com/apps → your app → App Manifest → Validate
```

### Local Development Verification

```bash
cd slack-bot && ./start.sh

# In Slack:
/do-snapshot-list
/do-droplet-list
/do-snapshot-delete          # shows selection buttons
/do-droplet-power-off <name>  # shows confirmation button
/do-droplet-create <name>    # shows snapshot selection buttons
/do-restore                  # now shows snapshot selection buttons
```

### Regression Checks

- `/do-snapshot` flow unchanged (shutdown + snapshot + restart prompts)
- `/do-restore <id>` still works when argument provided
- `/do-deploy-cancel <job-id>` still works
- No action ID conflicts with existing: `snapshot_shutdown_yes/no`, `snapshot_restart_yes/no`

### Lint Commands

```bash
cd slack-bot
uv run --with ruff ruff check bot.py
uv run --with pytest pytest tests/
```

---

## 10. Definition of Done

### Slack Commands
- [ ] All 9 new commands in `slack-bot/manifest.yml`
- [ ] All 9 new command handlers in `slack-bot/bot.py` following existing patterns
- [ ] `interactivity.is_enabled: true` in manifest
- [ ] Every command calls `_authorize()` with ephemeral unauthorized message
- [ ] Every destructive command (delete, power-off, resize) requires explicit confirmation
- [ ] Every command acknowledges within 3 seconds
- [ ] Long-running operations use `run_doctl_long()` with heartbeats
- [ ] Manifest re-applied at `api.slack.com`
- [ ] Each command tested manually (success + bad-args path)
- [ ] `docs/commands.md` updated with all new commands

### Bot Improvements
- [ ] `/do-restore` without arguments shows snapshot selection buttons (up to 5)
- [ ] Scheduled snapshot loop starts when `SNAPSHOT_SCHEDULE_INTERVAL_HOURS` is set
- [ ] Scheduled snapshots post to `SNAPSHOT_SCHEDULE_CHANNEL`
- [ ] Retention pruning runs after each snapshot when configured
- [ ] Pruning posts Slack summary of deleted snapshots
- [ ] New env vars documented in `.env.op.example` and `README-slack-bot.md`

### General
- [ ] No existing command behavior broken
- [ ] No files outside the listed change plan modified
- [ ] `pyproject.toml` unchanged
- [ ] No secrets committed

---

## 11. Open Questions

1. **`interactivity.request_url` in manifest:** Is `is_enabled: true` without a `request_url` field valid for this workspace's Slack app configuration? (Socket Mode does not use a URL, but some manifest validators may require the field.)

2. **SSH key selection for `/do-droplet-create`:** If the account has multiple SSH keys, should the bot use the first one, or should there be a `SLACK_DEFAULT_SSH_KEY_ID` env var?

3. **Reserved IP JSON field names:** Need to verify `doctl compute reserved-ip list --output json` field names (`ip`, `droplet_id`, etc.) against the live account before implementing `list_reserved_ips()`.

4. **Scheduled snapshot with multiple droplets:** If `SNAPSHOT_SCHEDULE_DROPLET` is not set and multiple droplets exist, should the bot post a warning and skip, or snapshot all of them?

5. **Retention "more aggressive wins":** When both `SNAPSHOT_RETENTION_DAYS` and `SNAPSHOT_RETENTION_COUNT` are set, a snapshot is pruned if it fails *either* rule. Is this the desired behavior vs. requiring both rules to be met?
