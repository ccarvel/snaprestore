#!/usr/bin/env python3
"""Slack Bolt bot for DO snapshot/restore operations via Socket Mode."""

import asyncio
import base64
import json
import os
import tempfile
import time
import uuid
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
            for d in droplets:
                if str(d["id"]) == droplet_hint or d["name"] == droplet_hint:
                    target = d
                    break
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

        # ask whether to shut down (only matters if droplet is active)
        shut_down = False
        if status == "active":
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

        # offer restart if we shut the droplet down
        if shut_down:
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
            if status == "active":
                await client.chat_postMessage(
                    channel=channel, thread_ts=thread_ts,
                    text="ℹ️ Droplet is still running (snapshot taken live).",
                )
            else:
                await client.chat_postMessage(
                    channel=channel, thread_ts=thread_ts,
                    text="💤 Droplet was already off. Use `/do-restore` to bring it back.",
                )

    except Exception as exc:
        await client.chat_postMessage(
            channel=channel, thread_ts=thread_ts,
            text=f"❌ Unexpected error in snapshot job `{job_id}`:\n```{exc}```",
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
            # sort by created_at descending, offer list
            sorted_snaps = sorted(snapshots,
                                   key=lambda x: x.get("created_at", ""),
                                   reverse=True)[:10]
            lines = "\n".join(
                f"  • `{s['id']}` — {s['name']} ({s.get('size_gigabytes', '?')} GB, "
                f"{s.get('created_at', '')[:10]})"
                for s in sorted_snaps
            )
            await client.chat_postMessage(
                channel=channel, thread_ts=thread_ts,
                text=(f"Use `/do-restore <snapshot-id-or-name>` to restore a specific snapshot.\n"
                      f"*Recent snapshots:*\n{lines}"),
            )
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

        # write welcome cloud-init to a temp file; IP not known yet so it's fetched
        # at boot time from the DO metadata API inside the cloud-init runcmd
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
        live_ip = next(
            (n["ip_address"] for n in new_droplet.get("networks", {}).get("v4", [])
             if n["type"] == "public"),
            None,
        )

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


# ── entry point ───────────────────────────────────────────────────────────────

async def main():
    handler = AsyncSocketModeHandler(app, os.environ["SLACK_APP_TOKEN"])
    await handler.start_async()


if __name__ == "__main__":
    asyncio.run(main())
