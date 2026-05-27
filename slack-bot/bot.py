#!/usr/bin/env python3
"""Slack Bolt bot for DO snapshot/restore operations via Socket Mode."""

import asyncio
import base64
import json
import os
import tempfile
import time
import uuid
from datetime import datetime, timezone
from pathlib import Path

import httpx
from slack_bolt.async_app import AsyncApp
from slack_bolt.adapter.socket_mode.async_handler import AsyncSocketModeHandler

# ── job state ─────────────────────────────────────────────────────────────────

JOBS_DIR = Path.home() / ".local/share/do-snap-bot/jobs"
JOBS_DIR.mkdir(parents=True, exist_ok=True)

ALLOWED_USERS: frozenset[str] = frozenset(
    u.strip()
    for u in os.environ.get("SLACK_ALLOWED_USERS", "").split(",")
    if u.strip()
)

# Keyed by conf_id; each entry: {"event": asyncio.Event, "value": str | None}
PENDING_CONFIRMATIONS: dict[str, dict] = {}

# ── app init ──────────────────────────────────────────────────────────────────

app = AsyncApp(
    token=os.environ["SLACK_BOT_TOKEN"],
    signing_secret=os.environ["SLACK_SIGNING_SECRET"],
)

# ── helpers ───────────────────────────────────────────────────────────────────

def _new_job_id() -> str:
    return str(uuid.uuid4())[:8]


def _cancel_path(job_id: str) -> Path:
    return JOBS_DIR / f"{job_id}.cancel"


def _is_cancelled(job_id: str) -> bool:
    return _cancel_path(job_id).exists()


def _authorize(user_id: str) -> bool:
    if not ALLOWED_USERS:
        return True
    return user_id in ALLOWED_USERS


async def run_doctl(*args: str, check: bool = True) -> tuple[int, str, str]:
    """Run doctl with args, capturing stdout/stderr via temp files to avoid pipe overflow."""
    with tempfile.NamedTemporaryFile(mode="r", suffix=".out", delete=False) as fout, \
         tempfile.NamedTemporaryFile(mode="r", suffix=".err", delete=False) as ferr:
        out_path, err_path = Path(fout.name), Path(ferr.name)

    try:
        proc = await asyncio.create_subprocess_exec(
            "doctl", *args,
            stdout=asyncio.subprocess.PIPE,
            stderr=asyncio.subprocess.PIPE,
        )
        stdout_b, stderr_b = await proc.communicate()
        out_path.write_bytes(stdout_b)
        err_path.write_bytes(stderr_b)
        rc = proc.returncode
        stdout = out_path.read_text().strip()
        stderr = err_path.read_text().strip()
        return rc, stdout, stderr
    finally:
        out_path.unlink(missing_ok=True)
        err_path.unlink(missing_ok=True)


async def run_doctl_long(
    job_id: str,
    client,
    channel: str,
    thread_ts: str,
    update_msg: str,
    *args: str,
    interval: int = 120,
) -> tuple[int, str, str]:
    """Run a long doctl --wait command, posting progress updates to Slack.

    Uses proc.wait() in a poll loop rather than proc.communicate() so the
    coroutine can be safely interrupted for heartbeats without cancellation
    issues. Output is buffered via PIPE and read after completion.
    """
    proc = await asyncio.create_subprocess_exec(
        "doctl", *args,
        stdout=asyncio.subprocess.PIPE,
        stderr=asyncio.subprocess.PIPE,
    )

    start = time.monotonic()
    while True:
        try:
            await asyncio.wait_for(asyncio.shield(proc.wait()), timeout=interval)
            # process finished — collect output
            stdout_b = await proc.stdout.read()
            stderr_b = await proc.stderr.read()
            return proc.returncode, stdout_b.decode().strip(), stderr_b.decode().strip()
        except asyncio.TimeoutError:
            if _is_cancelled(job_id):
                proc.kill()
                await proc.wait()
                return -2, "", "Cancelled by user."
            elapsed = int(time.monotonic() - start)
            m, s = divmod(elapsed, 60)
            await client.chat_postMessage(
                channel=channel,
                thread_ts=thread_ts,
                text=f"⏳ {update_msg} — {m:02d}:{s:02d} elapsed…",
            )


async def health_check(url: str, timeout: int = 300, interval: int = 10) -> bool:
    """Poll URL until HTTP 200 or timeout (seconds)."""
    deadline = time.monotonic() + timeout
    async with httpx.AsyncClient(verify=False, timeout=8) as client:
        while time.monotonic() < deadline:
            try:
                r = await client.get(url)
                if r.status_code == 200:
                    return True
            except Exception:
                pass
            await asyncio.sleep(interval)
    return False


def build_welcome_cloud_init(
    droplet_name: str,
    restore_ts: str,
    connect_ip: str,
) -> str:
    """Return cloud-init #cloud-config YAML that installs nginx with a welcome page."""
    html = f"""<!DOCTYPE html>
<html lang="en">
<head><meta charset="utf-8"><title>{droplet_name}</title>
<style>body{{font-family:monospace;max-width:600px;margin:60px auto;color:#eee;background:#1a1a2e}}
h1{{color:#00bcd4}}table{{border-collapse:collapse;width:100%}}
td{{padding:8px 12px;border-bottom:1px solid #333}}td:first-child{{color:#888;width:140px}}</style>
</head>
<body>
<h1>✦ {droplet_name} ✦</h1>
<p>Restored and running.</p>
<table>
<tr><td>Droplet</td><td>{droplet_name}</td></tr>
<tr><td>Restored at</td><td>{restore_ts}</td></tr>
<tr><td>IP</td><td>{connect_ip}</td></tr>
</table>
</body></html>"""

    html_b64 = base64.b64encode(html.encode()).decode()
    return f"""#cloud-config
packages:
  - nginx
write_files:
  - path: /tmp/welcome.html.b64
    content: |
      {html_b64}
runcmd:
  - base64 -d /tmp/welcome.html.b64 > /var/www/html/index.html
  - systemctl enable --now nginx
"""


# ── doctl query helpers ───────────────────────────────────────────────────────

async def list_droplets() -> list[dict]:
    rc, out, _ = await run_doctl("compute", "droplet", "list", "--output", "json")
    if rc != 0 or not out:
        return []
    return json.loads(out)


async def list_snapshots() -> list[dict]:
    rc, out, _ = await run_doctl("compute", "snapshot", "list",
                                  "--resource", "droplet", "--output", "json")
    if rc != 0 or not out:
        return []
    return json.loads(out)


async def get_droplet(droplet_id: str) -> dict | None:
    rc, out, _ = await run_doctl("compute", "droplet", "get",
                                  droplet_id, "--output", "json")
    if rc != 0 or not out:
        return None
    data = json.loads(out)
    return data[0] if data else None


async def list_ssh_keys() -> list[dict]:
    """Return all SSH keys registered with the DO account."""
    rc, out, _ = await run_doctl("compute", "ssh-key", "list", "--output", "json")
    if rc != 0 or not out:
        return []
    return json.loads(out)


async def list_reserved_ips() -> list[dict]:
    """Return all reserved IPs on the DO account."""
    rc, out, _ = await run_doctl("compute", "reserved-ip", "list", "--output", "json")
    if rc != 0 or not out:
        return []
    return json.loads(out)


async def delete_snapshot(snap_id: str) -> tuple[int, str, str]:
    """Delete a snapshot by ID (no confirmation — callers must confirm first)."""
    return await run_doctl("compute", "snapshot", "delete", str(snap_id), "--force")


async def delete_droplet(droplet_id: str) -> tuple[int, str, str]:
    """Delete a droplet by ID (no confirmation — callers must confirm first)."""
    return await run_doctl("compute", "droplet", "delete", str(droplet_id), "--force")


def _resolve_droplet(droplets: list[dict], hint: str) -> dict | None:
    """Find a droplet by name or ID from a pre-fetched list."""
    for d in droplets:
        if str(d["id"]) == hint or d["name"] == hint:
            return d
    return None


def _droplet_public_ip(droplet: dict) -> str | None:
    """Extract the public IPv4 address from a droplet dict."""
    return next(
        (n["ip_address"] for n in droplet.get("networks", {}).get("v4", [])
         if n["type"] == "public"),
        None,
    )


def _snap_age_days(snap: dict) -> float:
    """Return the age of a snapshot in days."""
    created = snap.get("created_at", "")
    if not created:
        return 0.0
    try:
        dt = datetime.fromisoformat(created.replace("Z", "+00:00"))
        return (datetime.now(tz=timezone.utc) - dt).total_seconds() / 86400
    except Exception:
        return 0.0


# ── confirmation helpers ──────────────────────────────────────────────────────

async def _ask_confirmation(
    client,
    channel: str,
    thread_ts: str,
    conf_id: str,
    question: str,
    yes_text: str,
    no_text: str,
    yes_action: str,
    no_action: str,
    timeout: int = 120,
) -> str | None:
    """Post Block Kit buttons and wait for user response.

    Returns 'yes', 'no', or None on timeout.
    """
    event = asyncio.Event()
    PENDING_CONFIRMATIONS[conf_id] = {"event": event, "value": None}

    await client.chat_postMessage(
        channel=channel,
        thread_ts=thread_ts,
        blocks=[
            {
                "type": "section",
                "text": {"type": "mrkdwn", "text": question},
            },
            {
                "type": "actions",
                "elements": [
                    {
                        "type": "button",
                        "text": {"type": "plain_text", "text": yes_text},
                        "style": "primary",
                        "action_id": yes_action,
                        "value": conf_id,
                    },
                    {
                        "type": "button",
                        "text": {"type": "plain_text", "text": no_text},
                        "action_id": no_action,
                        "value": conf_id,
                    },
                ],
            },
        ],
        text=question,
    )

    try:
        await asyncio.wait_for(event.wait(), timeout=timeout)
        return PENDING_CONFIRMATIONS.pop(conf_id, {}).get("value")
    except asyncio.TimeoutError:
        PENDING_CONFIRMATIONS.pop(conf_id, None)
        return None


def _resolve_confirmation(body: dict, value: str) -> None:
    """Called from action handlers to resolve a pending confirmation."""
    conf_id = body["actions"][0]["value"]
    entry = PENDING_CONFIRMATIONS.get(conf_id)
    if entry:
        entry["value"] = value
        entry["event"].set()


async def _ask_selection(
    client,
    channel: str,
    thread_ts: str,
    conf_id: str,
    question: str,
    options: list[tuple[str, str]],
    timeout: int = 120,
) -> str | None:
    """Post up to 5 labeled buttons for multi-item selection.

    Each option is a (label, value) tuple. Returns the selected value or None on timeout.
    The shared @app.action("selection_pick") handler resolves this.
    """
    event = asyncio.Event()
    PENDING_CONFIRMATIONS[conf_id] = {"event": event, "value": None}

    buttons = [
        {
            "type": "button",
            "text": {"type": "plain_text", "text": label[:75]},
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
        raw = PENDING_CONFIRMATIONS.pop(conf_id, {}).get("value") or ""
        # value stored as "conf_id:selected_value"
        return raw.split(":", 1)[1] if ":" in raw else raw
    except asyncio.TimeoutError:
        PENDING_CONFIRMATIONS.pop(conf_id, None)
        return None


# ── shared action handlers ────────────────────────────────────────────────────

@app.action("selection_pick")
async def action_selection_pick(ack, body, client):
    """Shared handler for all _ask_selection() multi-choice buttons."""
    await ack()
    raw_value = body["actions"][0]["value"]
    conf_id = raw_value.split(":", 1)[0]
    entry = PENDING_CONFIRMATIONS.get(conf_id)
    if entry:
        entry["value"] = raw_value  # full "conf_id:selected_value"
        entry["event"].set()
    label = body["actions"][0]["text"]["text"]
    await client.chat_update(
        channel=body["channel"]["id"],
        ts=body["message"]["ts"],
        blocks=[{
            "type": "section",
            "text": {"type": "mrkdwn", "text": f"✅ Selected: *{label}*"},
        }],
        text=f"Selected: {label}",
    )


# ── /do-snapshot ──────────────────────────────────────────────────────────────

@app.command("/do-snapshot")
async def cmd_snapshot(ack, body, client, say):
    await ack()
    user_id = body["user_id"]
    channel = body["channel_id"]

    if not _authorize(user_id):
        await client.chat_postEphemeral(channel=channel, user=user_id,
                                         text="⛔ You are not authorized to use this command.")
        return

    job_id = _new_job_id()
    ts_resp = await client.chat_postMessage(
        channel=channel,
        text=f"🔍 *Snapshot job `{job_id}` starting…*\nFetching droplets…",
    )
    thread_ts = ts_resp["ts"]

    asyncio.create_task(
        _snapshot_job(job_id, user_id, body.get("text", "").strip(),
                      client, channel, thread_ts)
    )


@app.action("snapshot_shutdown_yes")
async def action_shutdown_yes(ack, body, client):
    await ack()
    _resolve_confirmation(body, "yes")
    await client.chat_update(
        channel=body["channel"]["id"],
        ts=body["message"]["ts"],
        blocks=[{
            "type": "section",
            "text": {"type": "mrkdwn", "text": "✅ *Shutting down before snapshot.*"},
        }],
        text="Shutting down before snapshot.",
    )


@app.action("snapshot_shutdown_no")
async def action_shutdown_no(ack, body, client):
    await ack()
    _resolve_confirmation(body, "no")
    await client.chat_update(
        channel=body["channel"]["id"],
        ts=body["message"]["ts"],
        blocks=[{
            "type": "section",
            "text": {"type": "mrkdwn", "text": "⏭️ *Skipping shutdown — snapshotting live droplet.*"},
        }],
        text="Skipping shutdown — snapshotting live droplet.",
    )


@app.action("snapshot_restart_yes")
async def action_restart_yes(ack, body, client):
    await ack()
    _resolve_confirmation(body, "yes")
    await client.chat_update(
        channel=body["channel"]["id"],
        ts=body["message"]["ts"],
        blocks=[{
            "type": "section",
            "text": {"type": "mrkdwn", "text": "▶️ *Restarting droplet…*"},
        }],
        text="Restarting droplet…",
    )


@app.action("snapshot_restart_no")
async def action_restart_no(ack, body, client):
    await ack()
    _resolve_confirmation(body, "no")
    await client.chat_update(
        channel=body["channel"]["id"],
        ts=body["message"]["ts"],
        blocks=[{
            "type": "section",
            "text": {"type": "mrkdwn", "text": "💤 *Droplet left off.* Use `/do-restore` to bring it back."},
        }],
        text="Droplet left off.",
    )


async def _snapshot_job(
    job_id: str,
    user_id: str,
    droplet_hint: str,
    client,
    channel: str,
    thread_ts: str,
    scheduled: bool = False,
) -> None:
    try:
        droplets = await list_droplets()
        if not droplets:
            await client.chat_postMessage(channel=channel, thread_ts=thread_ts,
                                           text="❌ No droplets found.")
            return

        # match by name or ID if hint provided, else take first
        target = None
        if droplet_hint:
            target = _resolve_droplet(droplets, droplet_hint)
        if target is None:
            if len(droplets) == 1:
                target = droplets[0]
            else:
                lines = "\n".join(
                    f"  • `{d['id']}` — {d['name']} ({d['status']}, {d['region']['slug']})"
                    for d in droplets
                )
                await client.chat_postMessage(
                    channel=channel, thread_ts=thread_ts,
                    text=(f"Multiple droplets found. Re-run with the droplet name or ID:\n"
                          f"`/do-snapshot <name-or-id>`\n{lines}"),
                )
                return

        droplet_id = str(target["id"])
        droplet_name = target["name"]
        disk_gb = target.get("disk", 0)
        status = target["status"]
        snap_name = f"{droplet_name}-snapshot-{time.strftime('%Y%m%d-%H%M', time.gmtime())}"

        await client.chat_postMessage(
            channel=channel, thread_ts=thread_ts,
            text=(f"📋 *Droplet:* `{droplet_name}` (`{droplet_id}`)\n"
                  f"*Status:* {status}  *Disk:* {disk_gb} GB\n"
                  f"*Snapshot name:* `{snap_name}`"),
        )

        # ask whether to shut down (only if interactive — not for scheduled runs)
        shut_down = False
        if status == "active" and not scheduled:
            choice = await _ask_confirmation(
                client, channel, thread_ts,
                conf_id=f"{job_id}-shutdown",
                question=("*Shut down droplet before snapshotting?*\n"
                          "Recommended for a consistent snapshot. "
                          "Skip to snapshot the live (running) droplet."),
                yes_text="Shut down",
                no_text="Skip shutdown",
                yes_action="snapshot_shutdown_yes",
                no_action="snapshot_shutdown_no",
                timeout=120,
            )

            if choice is None:
                await client.chat_postMessage(
                    channel=channel, thread_ts=thread_ts,
                    text="⏱️ No response in 2 min — snapshotting live droplet.",
                )
            elif choice == "yes":
                await client.chat_postMessage(channel=channel, thread_ts=thread_ts,
                                               text="⏸ Shutting down droplet…")
                rc, _, err = await run_doctl_long(
                    job_id, client, channel, thread_ts, "Shutting down",
                    "compute", "droplet-action", "shutdown", droplet_id, "--wait",
                )
                if rc == -2:
                    await client.chat_postMessage(channel=channel, thread_ts=thread_ts,
                                                   text="🛑 Job cancelled.")
                    return
                if rc != 0:
                    await client.chat_postMessage(
                        channel=channel, thread_ts=thread_ts,
                        text=f"⚠️ Graceful shutdown failed — trying power-off…\n```{err[:300]}```",
                    )
                    rc2, _, err2 = await run_doctl_long(
                        job_id, client, channel, thread_ts, "Powering off",
                        "compute", "droplet-action", "power-off", droplet_id, "--wait",
                    )
                    if rc2 == -2:
                        await client.chat_postMessage(channel=channel, thread_ts=thread_ts,
                                                       text="🛑 Job cancelled.")
                        return
                    if rc2 != 0:
                        await client.chat_postMessage(
                            channel=channel, thread_ts=thread_ts,
                            text=f"❌ Power-off failed.\n```{err2[:300]}```",
                        )
                        return
                await client.chat_postMessage(channel=channel, thread_ts=thread_ts,
                                               text="✅ Droplet stopped.")
                shut_down = True

        if _is_cancelled(job_id):
            await client.chat_postMessage(channel=channel, thread_ts=thread_ts,
                                           text="🛑 Job cancelled.")
            return

        # create snapshot
        await client.chat_postMessage(channel=channel, thread_ts=thread_ts,
                                       text=f"📸 Creating snapshot `{snap_name}`…")
        snap_start = time.monotonic()
        rc, _, err = await run_doctl_long(
            job_id, client, channel, thread_ts, "Snapshotting",
            "compute", "droplet-action", "snapshot", droplet_id,
            "--snapshot-name", snap_name, "--wait",
        )
        if rc == -2:
            await client.chat_postMessage(channel=channel, thread_ts=thread_ts,
                                           text="🛑 Job cancelled.")
            return
        if rc != 0:
            await client.chat_postMessage(channel=channel, thread_ts=thread_ts,
                                           text=f"❌ Snapshot failed.\n```{err[:300]}```")
            return

        elapsed = int(time.monotonic() - snap_start)
        m, s = divmod(elapsed, 60)

        # fetch snapshot details
        rc2, snap_json_str, _ = await run_doctl(
            "compute", "snapshot", "list", "--resource", "droplet", "--output", "json"
        )
        cost_est = "?"
        snap_id = "?"
        snap_size = "?"
        if rc2 == 0 and snap_json_str:
            snaps = json.loads(snap_json_str)
            matches = [s for s in snaps if s.get("name") == snap_name]
            if matches:
                newest = sorted(matches, key=lambda x: x.get("created_at", ""))[-1]
                snap_id = newest.get("id", "?")
                snap_size = newest.get("size_gigabytes", "?")
                if isinstance(snap_size, (int, float)):
                    cost_est = f"${snap_size * 0.06:.2f}"

        await client.chat_postMessage(
            channel=channel, thread_ts=thread_ts,
            text=(f"✅ *Snapshot complete!* ({m:02d}:{s:02d})\n"
                  f"*ID:* `{snap_id}`  *Name:* `{snap_name}`\n"
                  f"*Size:* {snap_size} GB  *Est. cost:* {cost_est}/mo"),
        )

        # run retention policy if configured
        await _prune_snapshots(droplet_name, client, channel, thread_ts)

        # offer restart if we shut the droplet down (interactive only)
        if shut_down and not scheduled:
            restart_choice = await _ask_confirmation(
                client, channel, thread_ts,
                conf_id=f"{job_id}-restart",
                question="*Restart droplet now?*",
                yes_text="Restart",
                no_text="Leave off",
                yes_action="snapshot_restart_yes",
                no_action="snapshot_restart_no",
                timeout=120,
            )

            if restart_choice == "yes":
                rc_on, _, err_on = await run_doctl(
                    "compute", "droplet-action", "power-on", droplet_id, "--wait",
                )
                if rc_on == 0:
                    await client.chat_postMessage(
                        channel=channel, thread_ts=thread_ts,
                        text="🟢 Droplet is back online.",
                    )
                else:
                    await client.chat_postMessage(
                        channel=channel, thread_ts=thread_ts,
                        text=f"⚠️ Power-on failed.\n```{err_on[:300]}```",
                    )
            elif restart_choice is None:
                await client.chat_postMessage(
                    channel=channel, thread_ts=thread_ts,
                    text="⏱️ No response — droplet left off. Use `/do-restore` to bring it back.",
                )
            # "no" case: button handler already updated its own message; nothing extra needed
        else:
            if status == "active" and not scheduled:
                await client.chat_postMessage(
                    channel=channel, thread_ts=thread_ts,
                    text="ℹ️ Droplet is still running (snapshot taken live).",
                )
            elif not scheduled:
                await client.chat_postMessage(
                    channel=channel, thread_ts=thread_ts,
                    text="💤 Droplet was already off. Use `/do-restore` to bring it back.",
                )

    except Exception as exc:
        await client.chat_postMessage(
            channel=channel, thread_ts=thread_ts,
            text=f"❌ Unexpected error in snapshot job `{job_id}`:\n```{exc}```",
        )


# ── /do-snapshot-list ─────────────────────────────────────────────────────────

@app.command("/do-snapshot-list")
async def cmd_snapshot_list(ack, body, client):
    await ack()
    user_id = body["user_id"]
    channel = body["channel_id"]

    if not _authorize(user_id):
        await client.chat_postEphemeral(channel=channel, user=user_id,
                                         text="⛔ You are not authorized to use this command.")
        return

    snapshots = await list_snapshots()
    if not snapshots:
        await client.chat_postMessage(channel=channel, text="📭 No droplet snapshots found.")
        return

    sorted_snaps = sorted(snapshots, key=lambda x: x.get("created_at", ""), reverse=True)[:10]
    lines = []
    for s in sorted_snaps:
        size_gb = s.get("size_gigabytes", 0) or 0
        cost = f"${size_gb * 0.06:.2f}/mo"
        age = _snap_age_days(s)
        age_str = f"{int(age)}d" if age >= 1 else f"{int(age * 24)}h"
        regions = ", ".join(s.get("regions", [])) or "?"
        lines.append(
            f"• `{s['id']}` *{s['name']}*\n"
            f"  {size_gb} GB · {cost} · {regions} · {age_str} old"
        )

    await client.chat_postMessage(
        channel=channel,
        text=f"🗂️ *Droplet Snapshots* ({len(sorted_snaps)} shown):\n" + "\n".join(lines),
    )


# ── /do-snapshot-delete ───────────────────────────────────────────────────────

@app.command("/do-snapshot-delete")
async def cmd_snapshot_delete(ack, body, client):
    await ack()
    user_id = body["user_id"]
    channel = body["channel_id"]

    if not _authorize(user_id):
        await client.chat_postEphemeral(channel=channel, user=user_id,
                                         text="⛔ You are not authorized to use this command.")
        return

    job_id = _new_job_id()
    ts_resp = await client.chat_postMessage(
        channel=channel,
        text=f"🗑️ *Snapshot delete job `{job_id}` starting…*",
    )
    thread_ts = ts_resp["ts"]

    asyncio.create_task(
        _snapshot_delete_job(job_id, body.get("text", "").strip(),
                             client, channel, thread_ts)
    )


@app.action("snapshot_delete_confirm_yes")
async def action_snapshot_delete_yes(ack, body, client):
    await ack()
    _resolve_confirmation(body, "yes")
    await client.chat_update(
        channel=body["channel"]["id"],
        ts=body["message"]["ts"],
        blocks=[{
            "type": "section",
            "text": {"type": "mrkdwn", "text": "🗑️ *Deleting snapshot…*"},
        }],
        text="Deleting snapshot…",
    )


@app.action("snapshot_delete_confirm_no")
async def action_snapshot_delete_no(ack, body, client):
    await ack()
    _resolve_confirmation(body, "no")
    await client.chat_update(
        channel=body["channel"]["id"],
        ts=body["message"]["ts"],
        blocks=[{
            "type": "section",
            "text": {"type": "mrkdwn", "text": "↩️ *Cancelled — snapshot kept.*"},
        }],
        text="Cancelled — snapshot kept.",
    )


async def _snapshot_delete_job(
    job_id: str,
    snap_hint: str,
    client,
    channel: str,
    thread_ts: str,
) -> None:
    try:
        snapshots = await list_snapshots()
        if not snapshots:
            await client.chat_postMessage(channel=channel, thread_ts=thread_ts,
                                           text="❌ No droplet snapshots found.")
            return

        target_snap = None
        if snap_hint:
            for s in snapshots:
                if str(s.get("id")) == snap_hint or s.get("name") == snap_hint:
                    target_snap = s
                    break

        if target_snap is None:
            # offer selection via buttons (up to 5 most recent)
            sorted_snaps = sorted(snapshots, key=lambda x: x.get("created_at", ""), reverse=True)
            options = []
            for s in sorted_snaps[:5]:
                size_gb = s.get("size_gigabytes", 0) or 0
                age = _snap_age_days(s)
                age_str = f"{int(age)}d old"
                label = f"{s['name'][:40]} ({size_gb}GB, {age_str})"
                options.append((label, str(s["id"])))

            note = ""
            if len(sorted_snaps) > 5:
                note = f"\n_Showing 5 most recent of {len(sorted_snaps)}. Use `/do-snapshot-delete <id>` for others._"

            selected_id = await _ask_selection(
                client, channel, thread_ts,
                conf_id=f"{job_id}-select",
                question=f"*Which snapshot do you want to delete?*{note}",
                options=options,
                timeout=120,
            )
            if selected_id is None:
                await client.chat_postMessage(channel=channel, thread_ts=thread_ts,
                                               text="⏱️ No selection in 2 min — cancelled.")
                return
            for s in snapshots:
                if str(s.get("id")) == selected_id:
                    target_snap = s
                    break

        if target_snap is None:
            await client.chat_postMessage(channel=channel, thread_ts=thread_ts,
                                           text=f"❌ Snapshot `{snap_hint}` not found.")
            return

        snap_id = str(target_snap["id"])
        snap_name = target_snap["name"]
        size_gb = target_snap.get("size_gigabytes", "?")

        choice = await _ask_confirmation(
            client, channel, thread_ts,
            conf_id=f"{job_id}-confirm",
            question=f"⚠️ *Delete snapshot `{snap_name}` ({size_gb} GB)?* This cannot be undone.",
            yes_text="Delete",
            no_text="Cancel",
            yes_action="snapshot_delete_confirm_yes",
            no_action="snapshot_delete_confirm_no",
            timeout=120,
        )
        if choice != "yes":
            if choice is None:
                await client.chat_postMessage(channel=channel, thread_ts=thread_ts,
                                               text="⏱️ No response — snapshot kept.")
            return

        rc, _, err = await delete_snapshot(snap_id)
        if rc == 0:
            await client.chat_postMessage(channel=channel, thread_ts=thread_ts,
                                           text=f"✅ Snapshot `{snap_name}` deleted.")
        else:
            await client.chat_postMessage(channel=channel, thread_ts=thread_ts,
                                           text=f"❌ Delete failed.\n```{err[:300]}```")

    except Exception as exc:
        await client.chat_postMessage(
            channel=channel, thread_ts=thread_ts,
            text=f"❌ Unexpected error in snapshot-delete job `{job_id}`:\n```{exc}```",
        )


# ── /do-restore ───────────────────────────────────────────────────────────────

@app.command("/do-restore")
async def cmd_restore(ack, body, client, say):
    await ack()
    user_id = body["user_id"]
    channel = body["channel_id"]

    if not _authorize(user_id):
        await client.chat_postEphemeral(channel=channel, user=user_id,
                                         text="⛔ You are not authorized to use this command.")
        return

    job_id = _new_job_id()
    ts_resp = await client.chat_postMessage(
        channel=channel,
        text=f"🔍 *Restore job `{job_id}` starting…*\nFetching snapshots…",
    )
    thread_ts = ts_resp["ts"]

    asyncio.create_task(
        _restore_job(job_id, user_id, body.get("text", "").strip(),
                     client, channel, thread_ts)
    )


async def _restore_job(
    job_id: str,
    user_id: str,
    snap_hint: str,
    client,
    channel: str,
    thread_ts: str,
) -> None:
    try:
        snapshots = await list_snapshots()
        if not snapshots:
            await client.chat_postMessage(channel=channel, thread_ts=thread_ts,
                                           text="❌ No droplet snapshots found.")
            return

        target_snap = None
        if snap_hint:
            for s in snapshots:
                if str(s.get("id")) == snap_hint or s.get("name") == snap_hint:
                    target_snap = s
                    break

        if target_snap is None:
            # Bot improvement #1: button-based selection instead of text listing
            sorted_snaps = sorted(snapshots,
                                   key=lambda x: x.get("created_at", ""),
                                   reverse=True)
            options = []
            for s in sorted_snaps[:5]:
                size_gb = s.get("size_gigabytes", 0) or 0
                age = _snap_age_days(s)
                age_str = f"{int(age)}d old"
                label = f"{s['name'][:40]} ({size_gb}GB, {age_str})"
                options.append((label, str(s["id"])))

            note = ""
            if len(sorted_snaps) > 5:
                note = f"\n_Showing 5 most recent of {len(sorted_snaps)}. Use `/do-restore <id>` for others._"

            selected_id = await _ask_selection(
                client, channel, thread_ts,
                conf_id=f"{job_id}-select",
                question=f"*Which snapshot do you want to restore?*{note}",
                options=options,
                timeout=120,
            )
            if selected_id is None:
                await client.chat_postMessage(channel=channel, thread_ts=thread_ts,
                                               text="⏱️ No selection in 2 min — cancelled.")
                return
            for s in snapshots:
                if str(s.get("id")) == selected_id:
                    target_snap = s
                    break

        if target_snap is None:
            await client.chat_postMessage(channel=channel, thread_ts=thread_ts,
                                           text=f"❌ Snapshot `{snap_hint}` not found.")
            return

        snap_id = str(target_snap["id"])
        snap_name = target_snap["name"]
        min_disk = target_snap.get("min_disk_size", 25)
        regions = target_snap.get("regions", [])

        await client.chat_postMessage(
            channel=channel, thread_ts=thread_ts,
            text=(f"📋 *Snapshot:* `{snap_name}` (`{snap_id}`)\n"
                  f"*Min disk:* {min_disk} GB  *Regions:* {', '.join(regions)}"),
        )

        if _is_cancelled(job_id):
            await client.chat_postMessage(channel=channel, thread_ts=thread_ts,
                                           text="🛑 Job cancelled.")
            return

        # derive region from snapshot regions
        region = regions[0] if regions else "nyc3"

        # create new droplet from snapshot
        droplet_name = snap_name.rsplit("-snapshot-", 1)[0] if "-snapshot-" in snap_name else snap_name
        restore_ts = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())

        await client.chat_postMessage(channel=channel, thread_ts=thread_ts,
                                       text=f"🚀 Creating droplet `{droplet_name}` from snapshot…")

        size_slug = "s-1vcpu-1gb"  # minimal; user can override via hint

        cloud_init_yaml = build_welcome_cloud_init(
            droplet_name=droplet_name,
            restore_ts=restore_ts,
            connect_ip="(see Slack)",
        )
        cloud_init_tmp = Path(tempfile.mktemp(suffix=".yml"))
        cloud_init_tmp.write_text(cloud_init_yaml)

        create_start = time.monotonic()
        try:
            rc, out, err = await run_doctl_long(
                job_id, client, channel, thread_ts, "Creating droplet",
                "compute", "droplet", "create", droplet_name,
                "--image", snap_id,
                "--size", size_slug,
                "--region", region,
                "--user-data-file", str(cloud_init_tmp),
                "--wait",
                "--output", "json",
            )
        finally:
            cloud_init_tmp.unlink(missing_ok=True)
        if rc == -2:
            await client.chat_postMessage(channel=channel, thread_ts=thread_ts,
                                           text="🛑 Job cancelled.")
            return
        if rc != 0:
            await client.chat_postMessage(channel=channel, thread_ts=thread_ts,
                                           text=f"❌ Droplet creation failed.\n```{err[:400]}```")
            return

        new_droplets = json.loads(out) if out else []
        if not new_droplets:
            await client.chat_postMessage(channel=channel, thread_ts=thread_ts,
                                           text="❌ Droplet creation returned no data.")
            return

        new_droplet = new_droplets[0]
        new_droplet_id = str(new_droplet["id"])
        live_ip = _droplet_public_ip(new_droplet)

        elapsed = int(time.monotonic() - create_start)
        m, s = divmod(elapsed, 60)

        await client.chat_postMessage(
            channel=channel, thread_ts=thread_ts,
            text=(f"✅ *Droplet created!* ({m:02d}:{s:02d})\n"
                  f"*ID:* `{new_droplet_id}`  *Name:* `{droplet_name}`\n"
                  f"*IP:* `{live_ip or '(pending)'}`\n\n"
                  f"Running health check on http://{live_ip}…"),
        )

        if live_ip:
            ok = await health_check(f"http://{live_ip}", timeout=300, interval=10)
            if ok:
                await client.chat_postMessage(
                    channel=channel, thread_ts=thread_ts,
                    text=(f"🟢 Droplet is up — http://{live_ip} (nginx welcome page)\n"
                          f"`ssh root@{live_ip}`"),
                )
            else:
                await client.chat_postMessage(
                    channel=channel, thread_ts=thread_ts,
                    text=(f"⚠️ Health check timed out after 5 min — nginx may still be installing.\n"
                          f"Try http://{live_ip} in a moment — `ssh root@{live_ip}`"),
                )

    except Exception as exc:
        await client.chat_postMessage(
            channel=channel, thread_ts=thread_ts,
            text=f"❌ Unexpected error in restore job `{job_id}`:\n```{exc}```",
        )


# ── /do-droplet-list ──────────────────────────────────────────────────────────

@app.command("/do-droplet-list")
async def cmd_droplet_list(ack, body, client):
    await ack()
    user_id = body["user_id"]
    channel = body["channel_id"]

    if not _authorize(user_id):
        await client.chat_postEphemeral(channel=channel, user=user_id,
                                         text="⛔ You are not authorized to use this command.")
        return

    droplets = await list_droplets()
    if not droplets:
        await client.chat_postMessage(channel=channel, text="📭 No droplets found.")
        return

    status_emoji = {"active": "🟢", "off": "🔴", "archive": "📦"}
    lines = []
    for d in droplets:
        emoji = status_emoji.get(d["status"], "🟡")
        ip = _droplet_public_ip(d) or "—"
        region = d.get("region", {}).get("slug", "?")
        size = d.get("size_slug", "?")
        lines.append(
            f"{emoji} *{d['name']}* (`{d['id']}`)\n"
            f"  {d['status']} · {size} · {region} · `{ip}`"
        )

    await client.chat_postMessage(
        channel=channel,
        text=f"🖥️ *Droplets* ({len(droplets)} total):\n" + "\n".join(lines),
    )


# ── /do-droplet-power-on ─────────────────────────────────────────────────────

@app.command("/do-droplet-power-on")
async def cmd_droplet_power_on(ack, body, client):
    await ack()
    user_id = body["user_id"]
    channel = body["channel_id"]
    hint = body.get("text", "").strip()

    if not _authorize(user_id):
        await client.chat_postEphemeral(channel=channel, user=user_id,
                                         text="⛔ You are not authorized to use this command.")
        return

    if not hint:
        await client.chat_postEphemeral(channel=channel, user=user_id,
                                         text="Usage: `/do-droplet-power-on <name-or-id>`")
        return

    job_id = _new_job_id()
    ts_resp = await client.chat_postMessage(
        channel=channel,
        text=f"⚡ *Power-on job `{job_id}` starting…*",
    )
    thread_ts = ts_resp["ts"]

    asyncio.create_task(
        _droplet_power_on_job(job_id, hint, client, channel, thread_ts)
    )


async def _droplet_power_on_job(
    job_id: str,
    hint: str,
    client,
    channel: str,
    thread_ts: str,
) -> None:
    try:
        droplets = await list_droplets()
        target = _resolve_droplet(droplets, hint)
        if target is None:
            await client.chat_postMessage(channel=channel, thread_ts=thread_ts,
                                           text=f"❌ Droplet `{hint}` not found.")
            return

        droplet_id = str(target["id"])
        droplet_name = target["name"]

        if target["status"] == "active":
            await client.chat_postMessage(channel=channel, thread_ts=thread_ts,
                                           text=f"✅ Droplet `{droplet_name}` is already running.")
            return

        await client.chat_postMessage(channel=channel, thread_ts=thread_ts,
                                       text=f"⚡ Powering on `{droplet_name}`…")

        rc, _, err = await run_doctl_long(
            job_id, client, channel, thread_ts, "Powering on",
            "compute", "droplet-action", "power-on", droplet_id, "--wait",
        )
        if rc == 0:
            await client.chat_postMessage(channel=channel, thread_ts=thread_ts,
                                           text=f"🟢 Droplet `{droplet_name}` is online.")
        else:
            await client.chat_postMessage(channel=channel, thread_ts=thread_ts,
                                           text=f"❌ Power-on failed.\n```{err[:300]}```")

    except Exception as exc:
        await client.chat_postMessage(
            channel=channel, thread_ts=thread_ts,
            text=f"❌ Unexpected error in power-on job `{job_id}`:\n```{exc}```",
        )


# ── /do-droplet-power-off ─────────────────────────────────────────────────────

@app.command("/do-droplet-power-off")
async def cmd_droplet_power_off(ack, body, client):
    await ack()
    user_id = body["user_id"]
    channel = body["channel_id"]
    hint = body.get("text", "").strip()

    if not _authorize(user_id):
        await client.chat_postEphemeral(channel=channel, user=user_id,
                                         text="⛔ You are not authorized to use this command.")
        return

    if not hint:
        await client.chat_postEphemeral(channel=channel, user=user_id,
                                         text="Usage: `/do-droplet-power-off <name-or-id>`")
        return

    job_id = _new_job_id()
    ts_resp = await client.chat_postMessage(
        channel=channel,
        text=f"⏸ *Power-off job `{job_id}` starting…*",
    )
    thread_ts = ts_resp["ts"]

    asyncio.create_task(
        _droplet_power_off_job(job_id, hint, client, channel, thread_ts)
    )


@app.action("droplet_poweroff_confirm_yes")
async def action_droplet_poweroff_yes(ack, body, client):
    await ack()
    _resolve_confirmation(body, "yes")
    await client.chat_update(
        channel=body["channel"]["id"],
        ts=body["message"]["ts"],
        blocks=[{
            "type": "section",
            "text": {"type": "mrkdwn", "text": "⏸ *Shutting down droplet…*"},
        }],
        text="Shutting down droplet…",
    )


@app.action("droplet_poweroff_confirm_no")
async def action_droplet_poweroff_no(ack, body, client):
    await ack()
    _resolve_confirmation(body, "no")
    await client.chat_update(
        channel=body["channel"]["id"],
        ts=body["message"]["ts"],
        blocks=[{
            "type": "section",
            "text": {"type": "mrkdwn", "text": "↩️ *Power-off cancelled.*"},
        }],
        text="Power-off cancelled.",
    )


async def _droplet_power_off_job(
    job_id: str,
    hint: str,
    client,
    channel: str,
    thread_ts: str,
) -> None:
    try:
        droplets = await list_droplets()
        target = _resolve_droplet(droplets, hint)
        if target is None:
            await client.chat_postMessage(channel=channel, thread_ts=thread_ts,
                                           text=f"❌ Droplet `{hint}` not found.")
            return

        droplet_id = str(target["id"])
        droplet_name = target["name"]

        if target["status"] != "active":
            await client.chat_postMessage(channel=channel, thread_ts=thread_ts,
                                           text=f"✅ Droplet `{droplet_name}` is already off.")
            return

        choice = await _ask_confirmation(
            client, channel, thread_ts,
            conf_id=f"{job_id}-confirm",
            question=f"*Shut down droplet `{droplet_name}`?*\nGraceful shutdown with power-off fallback.",
            yes_text="Shut down",
            no_text="Cancel",
            yes_action="droplet_poweroff_confirm_yes",
            no_action="droplet_poweroff_confirm_no",
            timeout=120,
        )
        if choice != "yes":
            if choice is None:
                await client.chat_postMessage(channel=channel, thread_ts=thread_ts,
                                               text="⏱️ No response — power-off cancelled.")
            return

        rc, _, err = await run_doctl_long(
            job_id, client, channel, thread_ts, "Shutting down",
            "compute", "droplet-action", "shutdown", droplet_id, "--wait",
        )
        if rc != 0:
            await client.chat_postMessage(
                channel=channel, thread_ts=thread_ts,
                text=f"⚠️ Graceful shutdown failed — trying power-off…\n```{err[:300]}```",
            )
            rc2, _, err2 = await run_doctl_long(
                job_id, client, channel, thread_ts, "Powering off",
                "compute", "droplet-action", "power-off", droplet_id, "--wait",
            )
            if rc2 != 0:
                await client.chat_postMessage(channel=channel, thread_ts=thread_ts,
                                               text=f"❌ Power-off failed.\n```{err2[:300]}```")
                return

        await client.chat_postMessage(channel=channel, thread_ts=thread_ts,
                                       text=f"✅ Droplet `{droplet_name}` is stopped.")

    except Exception as exc:
        await client.chat_postMessage(
            channel=channel, thread_ts=thread_ts,
            text=f"❌ Unexpected error in power-off job `{job_id}`:\n```{exc}```",
        )


# ── /do-droplet-delete ────────────────────────────────────────────────────────

@app.command("/do-droplet-delete")
async def cmd_droplet_delete(ack, body, client):
    await ack()
    user_id = body["user_id"]
    channel = body["channel_id"]
    hint = body.get("text", "").strip()

    if not _authorize(user_id):
        await client.chat_postEphemeral(channel=channel, user=user_id,
                                         text="⛔ You are not authorized to use this command.")
        return

    if not hint:
        await client.chat_postEphemeral(channel=channel, user=user_id,
                                         text="Usage: `/do-droplet-delete <name-or-id>`")
        return

    job_id = _new_job_id()
    ts_resp = await client.chat_postMessage(
        channel=channel,
        text=f"🗑️ *Droplet delete job `{job_id}` starting…*",
    )
    thread_ts = ts_resp["ts"]

    asyncio.create_task(
        _droplet_delete_job(job_id, hint, client, channel, thread_ts)
    )


@app.action("droplet_delete_confirm_yes")
async def action_droplet_delete_yes(ack, body, client):
    await ack()
    _resolve_confirmation(body, "yes")
    await client.chat_update(
        channel=body["channel"]["id"],
        ts=body["message"]["ts"],
        blocks=[{
            "type": "section",
            "text": {"type": "mrkdwn", "text": "🗑️ *Deleting droplet…*"},
        }],
        text="Deleting droplet…",
    )


@app.action("droplet_delete_confirm_no")
async def action_droplet_delete_no(ack, body, client):
    await ack()
    _resolve_confirmation(body, "no")
    await client.chat_update(
        channel=body["channel"]["id"],
        ts=body["message"]["ts"],
        blocks=[{
            "type": "section",
            "text": {"type": "mrkdwn", "text": "↩️ *Deletion cancelled.*"},
        }],
        text="Deletion cancelled.",
    )


async def _droplet_delete_job(
    job_id: str,
    hint: str,
    client,
    channel: str,
    thread_ts: str,
) -> None:
    try:
        droplets = await list_droplets()
        target = _resolve_droplet(droplets, hint)
        if target is None:
            await client.chat_postMessage(channel=channel, thread_ts=thread_ts,
                                           text=f"❌ Droplet `{hint}` not found.")
            return

        droplet_id = str(target["id"])
        droplet_name = target["name"]

        # check for recent snapshot (within 7 days)
        snapshots = await list_snapshots()
        recent_snaps = [
            s for s in snapshots
            if s.get("name", "").startswith(f"{droplet_name}-snapshot-")
            and _snap_age_days(s) <= 7
        ]
        warning = ""
        if not recent_snaps:
            warning = "\n⚠️ *No recent snapshot found (last 7 days).* Data will be permanently lost."

        choice = await _ask_confirmation(
            client, channel, thread_ts,
            conf_id=f"{job_id}-confirm",
            question=f"*Delete droplet `{droplet_name}` (`{droplet_id}`)?* This cannot be undone.{warning}",
            yes_text="Delete",
            no_text="Cancel",
            yes_action="droplet_delete_confirm_yes",
            no_action="droplet_delete_confirm_no",
            timeout=120,
        )
        if choice != "yes":
            if choice is None:
                await client.chat_postMessage(channel=channel, thread_ts=thread_ts,
                                               text="⏱️ No response — deletion cancelled.")
            return

        rc, _, err = await delete_droplet(droplet_id)
        if rc == 0:
            await client.chat_postMessage(channel=channel, thread_ts=thread_ts,
                                           text=f"✅ Droplet `{droplet_name}` deleted.")
        else:
            await client.chat_postMessage(channel=channel, thread_ts=thread_ts,
                                           text=f"❌ Delete failed.\n```{err[:300]}```")

    except Exception as exc:
        await client.chat_postMessage(
            channel=channel, thread_ts=thread_ts,
            text=f"❌ Unexpected error in droplet-delete job `{job_id}`:\n```{exc}```",
        )


# ── /do-droplet-resize ────────────────────────────────────────────────────────

@app.command("/do-droplet-resize")
async def cmd_droplet_resize(ack, body, client):
    await ack()
    user_id = body["user_id"]
    channel = body["channel_id"]
    args = body.get("text", "").strip().split()

    if not _authorize(user_id):
        await client.chat_postEphemeral(channel=channel, user=user_id,
                                         text="⛔ You are not authorized to use this command.")
        return

    if len(args) < 2:
        await client.chat_postEphemeral(channel=channel, user=user_id,
                                         text="Usage: `/do-droplet-resize <name-or-id> <size-slug>`\n"
                                              "Example: `/do-droplet-resize my-droplet s-2vcpu-2gb`")
        return

    hint, size_slug = args[0], args[1]

    job_id = _new_job_id()
    ts_resp = await client.chat_postMessage(
        channel=channel,
        text=f"📐 *Resize job `{job_id}` starting…*",
    )
    thread_ts = ts_resp["ts"]

    asyncio.create_task(
        _droplet_resize_job(job_id, hint, size_slug, client, channel, thread_ts)
    )


@app.action("droplet_resize_poweroff_yes")
async def action_droplet_resize_poweroff_yes(ack, body, client):
    await ack()
    _resolve_confirmation(body, "yes")
    await client.chat_update(
        channel=body["channel"]["id"],
        ts=body["message"]["ts"],
        blocks=[{
            "type": "section",
            "text": {"type": "mrkdwn", "text": "⏸ *Powering off for resize…*"},
        }],
        text="Powering off for resize…",
    )


@app.action("droplet_resize_poweroff_no")
async def action_droplet_resize_poweroff_no(ack, body, client):
    await ack()
    _resolve_confirmation(body, "no")
    await client.chat_update(
        channel=body["channel"]["id"],
        ts=body["message"]["ts"],
        blocks=[{
            "type": "section",
            "text": {"type": "mrkdwn", "text": "↩️ *Resize cancelled.*"},
        }],
        text="Resize cancelled.",
    )


@app.action("droplet_resize_poweron_yes")
async def action_droplet_resize_poweron_yes(ack, body, client):
    await ack()
    _resolve_confirmation(body, "yes")
    await client.chat_update(
        channel=body["channel"]["id"],
        ts=body["message"]["ts"],
        blocks=[{
            "type": "section",
            "text": {"type": "mrkdwn", "text": "▶️ *Powering on after resize…*"},
        }],
        text="Powering on after resize…",
    )


@app.action("droplet_resize_poweron_no")
async def action_droplet_resize_poweron_no(ack, body, client):
    await ack()
    _resolve_confirmation(body, "no")
    await client.chat_update(
        channel=body["channel"]["id"],
        ts=body["message"]["ts"],
        blocks=[{
            "type": "section",
            "text": {"type": "mrkdwn", "text": "💤 *Droplet left off after resize.*"},
        }],
        text="Droplet left off after resize.",
    )


async def _droplet_resize_job(
    job_id: str,
    hint: str,
    size_slug: str,
    client,
    channel: str,
    thread_ts: str,
) -> None:
    try:
        droplets = await list_droplets()
        target = _resolve_droplet(droplets, hint)
        if target is None:
            await client.chat_postMessage(channel=channel, thread_ts=thread_ts,
                                           text=f"❌ Droplet `{hint}` not found.")
            return

        droplet_id = str(target["id"])
        droplet_name = target["name"]
        current_size = target.get("size_slug", "?")

        choice = await _ask_confirmation(
            client, channel, thread_ts,
            conf_id=f"{job_id}-poweroff",
            question=(f"*Resize `{droplet_name}` from `{current_size}` → `{size_slug}`?*\n"
                      "This requires a brief power-off. The bot will power off, resize, "
                      "then offer to power back on."),
            yes_text="Power off & resize",
            no_text="Cancel",
            yes_action="droplet_resize_poweroff_yes",
            no_action="droplet_resize_poweroff_no",
            timeout=120,
        )
        if choice != "yes":
            if choice is None:
                await client.chat_postMessage(channel=channel, thread_ts=thread_ts,
                                               text="⏱️ No response — resize cancelled.")
            return

        # power off if active
        if target["status"] == "active":
            rc, _, err = await run_doctl_long(
                job_id, client, channel, thread_ts, "Powering off",
                "compute", "droplet-action", "power-off", droplet_id, "--wait",
            )
            if rc == -2:
                await client.chat_postMessage(channel=channel, thread_ts=thread_ts,
                                               text="🛑 Job cancelled.")
                return
            if rc != 0:
                await client.chat_postMessage(channel=channel, thread_ts=thread_ts,
                                               text=f"❌ Power-off failed.\n```{err[:300]}```")
                return
            await client.chat_postMessage(channel=channel, thread_ts=thread_ts,
                                           text="✅ Droplet stopped. Resizing…")

        rc, _, err = await run_doctl_long(
            job_id, client, channel, thread_ts, "Resizing",
            "compute", "droplet-action", "resize", droplet_id,
            "--size", size_slug, "--wait",
        )
        if rc == -2:
            await client.chat_postMessage(channel=channel, thread_ts=thread_ts,
                                           text="🛑 Job cancelled.")
            return
        if rc != 0:
            await client.chat_postMessage(channel=channel, thread_ts=thread_ts,
                                           text=f"❌ Resize failed.\n```{err[:300]}```")
            return

        await client.chat_postMessage(channel=channel, thread_ts=thread_ts,
                                       text=f"✅ Droplet `{droplet_name}` resized to `{size_slug}`.")

        # offer to power back on
        restart = await _ask_confirmation(
            client, channel, thread_ts,
            conf_id=f"{job_id}-poweron",
            question="*Power the droplet back on?*",
            yes_text="Power on",
            no_text="Leave off",
            yes_action="droplet_resize_poweron_yes",
            no_action="droplet_resize_poweron_no",
            timeout=120,
        )
        if restart == "yes":
            rc_on, _, err_on = await run_doctl(
                "compute", "droplet-action", "power-on", droplet_id, "--wait",
            )
            if rc_on == 0:
                await client.chat_postMessage(channel=channel, thread_ts=thread_ts,
                                               text="🟢 Droplet is back online.")
            else:
                await client.chat_postMessage(channel=channel, thread_ts=thread_ts,
                                               text=f"⚠️ Power-on failed.\n```{err_on[:300]}```")
        elif restart is None:
            await client.chat_postMessage(channel=channel, thread_ts=thread_ts,
                                           text="⏱️ No response — droplet left off.")

    except Exception as exc:
        await client.chat_postMessage(
            channel=channel, thread_ts=thread_ts,
            text=f"❌ Unexpected error in resize job `{job_id}`:\n```{exc}```",
        )


# ── /do-droplet-create ────────────────────────────────────────────────────────

@app.command("/do-droplet-create")
async def cmd_droplet_create(ack, body, client):
    await ack()
    user_id = body["user_id"]
    channel = body["channel_id"]

    if not _authorize(user_id):
        await client.chat_postEphemeral(channel=channel, user=user_id,
                                         text="⛔ You are not authorized to use this command.")
        return

    args = body.get("text", "").strip().split()
    if not args:
        await client.chat_postEphemeral(
            channel=channel, user=user_id,
            text="Usage: `/do-droplet-create <name> [size] [image-id-or-snapshot-name]`\n"
                 "Example: `/do-droplet-create my-server s-1vcpu-1gb`",
        )
        return

    droplet_name = args[0]
    size_slug = args[1] if len(args) > 1 else "s-1vcpu-1gb"
    image_hint = args[2] if len(args) > 2 else ""

    job_id = _new_job_id()
    ts_resp = await client.chat_postMessage(
        channel=channel,
        text=f"🚀 *Droplet create job `{job_id}` starting…*",
    )
    thread_ts = ts_resp["ts"]

    asyncio.create_task(
        _droplet_create_job(job_id, droplet_name, size_slug, image_hint,
                            client, channel, thread_ts)
    )


async def _droplet_create_job(
    job_id: str,
    droplet_name: str,
    size_slug: str,
    image_hint: str,
    client,
    channel: str,
    thread_ts: str,
) -> None:
    try:
        # resolve image
        image_id = image_hint
        if not image_id:
            snapshots = await list_snapshots()
            if not snapshots:
                await client.chat_postMessage(channel=channel, thread_ts=thread_ts,
                                               text="❌ No snapshots found. Provide an image ID or snapshot name.")
                return

            sorted_snaps = sorted(snapshots, key=lambda x: x.get("created_at", ""), reverse=True)
            options = []
            for s in sorted_snaps[:5]:
                size_gb = s.get("size_gigabytes", 0) or 0
                age = _snap_age_days(s)
                label = f"{s['name'][:40]} ({size_gb}GB, {int(age)}d old)"
                options.append((label, str(s["id"])))

            note = ""
            if len(sorted_snaps) > 5:
                note = f"\n_Showing 5 most recent of {len(sorted_snaps)}._"

            image_id = await _ask_selection(
                client, channel, thread_ts,
                conf_id=f"{job_id}-image",
                question=f"*Select a snapshot to create `{droplet_name}` from:*{note}",
                options=options,
                timeout=120,
            )
            if image_id is None:
                await client.chat_postMessage(channel=channel, thread_ts=thread_ts,
                                               text="⏱️ No selection in 2 min — cancelled.")
                return
        else:
            # resolve name to ID if needed
            if not image_id.isdigit():
                snapshots = await list_snapshots()
                for s in snapshots:
                    if s.get("name") == image_id:
                        image_id = str(s["id"])
                        break

        # look up SSH keys
        ssh_keys = await list_ssh_keys()
        ssh_key_args = []
        if ssh_keys:
            ssh_key_args = ["--ssh-keys", str(ssh_keys[0]["id"])]

        # derive region
        snapshots = await list_snapshots()
        region = "nyc3"
        for s in snapshots:
            if str(s.get("id")) == image_id:
                regions = s.get("regions", [])
                if regions:
                    region = regions[0]
                break

        restore_ts = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())
        cloud_init_yaml = build_welcome_cloud_init(
            droplet_name=droplet_name,
            restore_ts=restore_ts,
            connect_ip="(see Slack)",
        )
        cloud_init_tmp = Path(tempfile.mktemp(suffix=".yml"))
        cloud_init_tmp.write_text(cloud_init_yaml)

        await client.chat_postMessage(
            channel=channel, thread_ts=thread_ts,
            text=f"🚀 Creating droplet `{droplet_name}` (size: `{size_slug}`, region: `{region}`)…",
        )

        create_start = time.monotonic()
        try:
            rc, out, err = await run_doctl_long(
                job_id, client, channel, thread_ts, "Creating droplet",
                "compute", "droplet", "create", droplet_name,
                "--image", str(image_id),
                "--size", size_slug,
                "--region", region,
                "--user-data-file", str(cloud_init_tmp),
                "--wait",
                "--output", "json",
                *ssh_key_args,
            )
        finally:
            cloud_init_tmp.unlink(missing_ok=True)

        if rc == -2:
            await client.chat_postMessage(channel=channel, thread_ts=thread_ts,
                                           text="🛑 Job cancelled.")
            return
        if rc != 0:
            await client.chat_postMessage(channel=channel, thread_ts=thread_ts,
                                           text=f"❌ Droplet creation failed.\n```{err[:400]}```")
            return

        new_droplets = json.loads(out) if out else []
        if not new_droplets:
            await client.chat_postMessage(channel=channel, thread_ts=thread_ts,
                                           text="❌ Droplet creation returned no data.")
            return

        new_droplet = new_droplets[0]
        new_droplet_id = str(new_droplet["id"])
        live_ip = _droplet_public_ip(new_droplet)

        elapsed = int(time.monotonic() - create_start)
        m, s = divmod(elapsed, 60)

        await client.chat_postMessage(
            channel=channel, thread_ts=thread_ts,
            text=(f"✅ *Droplet created!* ({m:02d}:{s:02d})\n"
                  f"*ID:* `{new_droplet_id}`  *Name:* `{droplet_name}`\n"
                  f"*IP:* `{live_ip or '(pending)'}`"),
        )

        if live_ip:
            ok = await health_check(f"http://{live_ip}", timeout=300, interval=10)
            if ok:
                await client.chat_postMessage(
                    channel=channel, thread_ts=thread_ts,
                    text=(f"🟢 Droplet is up — http://{live_ip}\n"
                          f"`ssh root@{live_ip}`"),
                )
            else:
                await client.chat_postMessage(
                    channel=channel, thread_ts=thread_ts,
                    text=(f"⚠️ Health check timed out — try http://{live_ip} in a moment.\n"
                          f"`ssh root@{live_ip}`"),
                )

    except Exception as exc:
        await client.chat_postMessage(
            channel=channel, thread_ts=thread_ts,
            text=f"❌ Unexpected error in droplet-create job `{job_id}`:\n```{exc}```",
        )


# ── /do-reserved-ip-assign ────────────────────────────────────────────────────

@app.command("/do-reserved-ip-assign")
async def cmd_reserved_ip_assign(ack, body, client):
    await ack()
    user_id = body["user_id"]
    channel = body["channel_id"]
    args = body.get("text", "").strip().split()

    if not _authorize(user_id):
        await client.chat_postEphemeral(channel=channel, user=user_id,
                                         text="⛔ You are not authorized to use this command.")
        return

    if len(args) < 2:
        await client.chat_postEphemeral(
            channel=channel, user=user_id,
            text="Usage: `/do-reserved-ip-assign <ip> <droplet-name-or-id>`",
        )
        return

    ip_addr, droplet_hint = args[0], args[1]

    job_id = _new_job_id()
    ts_resp = await client.chat_postMessage(
        channel=channel,
        text=f"🌐 *Reserved IP assign job `{job_id}` starting…*",
    )
    thread_ts = ts_resp["ts"]

    asyncio.create_task(
        _reserved_ip_assign_job(job_id, ip_addr, droplet_hint, client, channel, thread_ts)
    )


async def _reserved_ip_assign_job(
    job_id: str,
    ip_addr: str,
    droplet_hint: str,
    client,
    channel: str,
    thread_ts: str,
) -> None:
    try:
        # resolve droplet
        droplets = await list_droplets()
        target = _resolve_droplet(droplets, droplet_hint)
        if target is None:
            await client.chat_postMessage(channel=channel, thread_ts=thread_ts,
                                           text=f"❌ Droplet `{droplet_hint}` not found.")
            return

        droplet_id = str(target["id"])
        droplet_name = target["name"]

        # validate reserved IP exists on account
        reserved_ips = await list_reserved_ips()
        ip_found = any(r.get("ip") == ip_addr for r in reserved_ips)
        if not ip_found:
            await client.chat_postMessage(
                channel=channel, thread_ts=thread_ts,
                text=f"❌ Reserved IP `{ip_addr}` not found on this account.",
            )
            return

        await client.chat_postMessage(
            channel=channel, thread_ts=thread_ts,
            text=f"🌐 Assigning `{ip_addr}` to `{droplet_name}` (`{droplet_id}`)…",
        )

        rc, _, err = await run_doctl(
            "compute", "reserved-ip-action", "assign", ip_addr, droplet_id,
        )
        if rc == 0:
            await client.chat_postMessage(
                channel=channel, thread_ts=thread_ts,
                text=f"✅ Reserved IP `{ip_addr}` assigned to `{droplet_name}`.",
            )
        else:
            await client.chat_postMessage(
                channel=channel, thread_ts=thread_ts,
                text=f"❌ Assignment failed.\n```{err[:300]}```",
            )

    except Exception as exc:
        await client.chat_postMessage(
            channel=channel, thread_ts=thread_ts,
            text=f"❌ Unexpected error in reserved-ip-assign job `{job_id}`:\n```{exc}```",
        )


# ── /do-deploy-cancel ─────────────────────────────────────────────────────────

@app.command("/do-deploy-cancel")
async def cmd_cancel(ack, body, client):
    await ack()
    user_id = body["user_id"]
    channel = body["channel_id"]
    job_id = body.get("text", "").strip()

    if not _authorize(user_id):
        await client.chat_postEphemeral(channel=channel, user=user_id,
                                         text="⛔ You are not authorized to use this command.")
        return

    if not job_id:
        await client.chat_postEphemeral(
            channel=channel, user=user_id,
            text="Usage: `/do-deploy-cancel <job-id>`",
        )
        return

    _cancel_path(job_id).touch()
    await client.chat_postMessage(
        channel=channel,
        text=f"🛑 Cancellation requested for job `{job_id}`.",
    )


# ── bot improvement #3: snapshot retention ────────────────────────────────────

async def _prune_snapshots(
    droplet_name: str,
    client,
    channel: str,
    thread_ts: str,
) -> None:
    """Delete old snapshots for a droplet based on retention policy env vars.

    SNAPSHOT_RETENTION_DAYS  — delete snapshots older than N days.
    SNAPSHOT_RETENTION_COUNT — keep only the N most recent snapshots.
    If both are set, the more aggressive rule wins (prune if either rule is triggered).
    Does nothing if neither env var is set.
    """
    retention_days_str = os.environ.get("SNAPSHOT_RETENTION_DAYS", "").strip()
    retention_count_str = os.environ.get("SNAPSHOT_RETENTION_COUNT", "").strip()

    if not retention_days_str and not retention_count_str:
        return

    retention_days = float(retention_days_str) if retention_days_str else None
    retention_count = int(retention_count_str) if retention_count_str else None

    all_snaps = await list_snapshots()
    # filter to snapshots belonging to this droplet
    own_snaps = [
        s for s in all_snaps
        if s.get("name", "").startswith(f"{droplet_name}-snapshot-")
    ]
    if not own_snaps:
        return

    # sort newest-first for count-based retention
    own_snaps_sorted = sorted(own_snaps, key=lambda x: x.get("created_at", ""), reverse=True)

    to_delete: set[str] = set()

    # apply days rule
    if retention_days is not None:
        for s in own_snaps_sorted:
            if _snap_age_days(s) > retention_days:
                to_delete.add(str(s["id"]))

    # apply count rule
    if retention_count is not None:
        for s in own_snaps_sorted[retention_count:]:
            to_delete.add(str(s["id"]))

    if not to_delete:
        return

    pruned_names = []
    failed_ids = []
    for s in own_snaps_sorted:
        sid = str(s["id"])
        if sid in to_delete:
            rc, _, err = await delete_snapshot(sid)
            if rc == 0:
                pruned_names.append(s["name"])
            else:
                failed_ids.append(sid)

    if pruned_names:
        names_list = ", ".join(f"`{n}`" for n in pruned_names)
        await client.chat_postMessage(
            channel=channel, thread_ts=thread_ts,
            text=f"🗑️ *Retention policy:* pruned {len(pruned_names)} snapshot(s): {names_list}",
        )
    if failed_ids:
        await client.chat_postMessage(
            channel=channel, thread_ts=thread_ts,
            text=f"⚠️ Failed to delete {len(failed_ids)} snapshot(s): {', '.join(f'`{i}`' for i in failed_ids)}",
        )


# ── bot improvement #2: scheduled snapshots ───────────────────────────────────

async def _scheduled_snapshot_loop(client) -> None:
    """Background loop that auto-snapshots on a configured interval.

    Reads env vars:
        SNAPSHOT_SCHEDULE_INTERVAL_HOURS — interval in hours (float)
        SNAPSHOT_SCHEDULE_CHANNEL        — Slack channel ID to post results
        SNAPSHOT_SCHEDULE_DROPLET        — droplet name or ID (optional if only one exists)
    """
    interval_str = os.environ.get("SNAPSHOT_SCHEDULE_INTERVAL_HOURS", "").strip()
    channel = os.environ.get("SNAPSHOT_SCHEDULE_CHANNEL", "").strip()
    droplet_hint = os.environ.get("SNAPSHOT_SCHEDULE_DROPLET", "").strip()

    if not interval_str or not channel:
        return  # scheduling not configured

    try:
        interval_hours = float(interval_str)
    except ValueError:
        return

    interval_seconds = interval_hours * 3600

    while True:
        await asyncio.sleep(interval_seconds)

        job_id = _new_job_id()
        try:
            ts_resp = await client.chat_postMessage(
                channel=channel,
                text=f"⏰ *Scheduled snapshot job `{job_id}` starting…*",
            )
            thread_ts = ts_resp["ts"]

            # resolve droplet if not specified
            hint = droplet_hint
            if not hint:
                droplets = await list_droplets()
                if len(droplets) == 1:
                    hint = str(droplets[0]["id"])
                elif len(droplets) == 0:
                    await client.chat_postMessage(
                        channel=channel, thread_ts=thread_ts,
                        text="❌ No droplets found for scheduled snapshot.",
                    )
                    continue
                else:
                    names = ", ".join(f"`{d['name']}`" for d in droplets)
                    await client.chat_postMessage(
                        channel=channel, thread_ts=thread_ts,
                        text=(f"⚠️ Multiple droplets found ({names}). "
                              "Set `SNAPSHOT_SCHEDULE_DROPLET` to specify which one to auto-snapshot."),
                    )
                    continue

            await _snapshot_job(job_id, "scheduler", hint, client, channel, thread_ts,
                                scheduled=True)

        except Exception as exc:
            try:
                await client.chat_postMessage(
                    channel=channel,
                    text=f"❌ Scheduled snapshot job `{job_id}` failed:\n```{exc}```",
                )
            except Exception:
                pass


# ── entry point ───────────────────────────────────────────────────────────────

async def main():
    handler = AsyncSocketModeHandler(app, os.environ["SLACK_APP_TOKEN"])

    # start scheduled snapshot loop if configured
    interval_str = os.environ.get("SNAPSHOT_SCHEDULE_INTERVAL_HOURS", "").strip()
    schedule_channel = os.environ.get("SNAPSHOT_SCHEDULE_CHANNEL", "").strip()
    if interval_str and schedule_channel:
        asyncio.create_task(_scheduled_snapshot_loop(app.client))

    await handler.start_async()


if __name__ == "__main__":
    asyncio.run(main())
