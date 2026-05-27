"""Minimal unit tests for bot.py helper functions.

Run with: uv run --with pytest pytest tests/
"""

import asyncio
import json
import os
from datetime import datetime, timezone, timedelta
from unittest.mock import AsyncMock, MagicMock, patch

import pytest

# ── helpers that can be tested without the Slack app running ──────────────────

# Import only the pure helpers — don't trigger app init which needs env vars
import sys
import types

# Stub out slack_bolt before importing bot so we don't need Slack credentials
slack_bolt_stub = types.ModuleType("slack_bolt")
slack_bolt_async_stub = types.ModuleType("slack_bolt.async_app")


class _FakeAsyncApp:
    def __init__(self, **kwargs):
        self.client = None

    def command(self, *a, **kw):
        def decorator(f):
            return f
        return decorator

    def action(self, *a, **kw):
        def decorator(f):
            return f
        return decorator


slack_bolt_async_stub.AsyncApp = _FakeAsyncApp
slack_bolt_stub.async_app = slack_bolt_async_stub
sys.modules.setdefault("slack_bolt", slack_bolt_stub)
sys.modules.setdefault("slack_bolt.async_app", slack_bolt_async_stub)

adapter_stub = types.ModuleType("slack_bolt.adapter.socket_mode.async_handler")


class _FakeHandler:
    def __init__(self, *a, **kw):
        pass
    async def start_async(self):
        pass


adapter_stub.AsyncSocketModeHandler = _FakeHandler
sys.modules.setdefault("slack_bolt.adapter", types.ModuleType("slack_bolt.adapter"))
sys.modules.setdefault("slack_bolt.adapter.socket_mode", types.ModuleType("slack_bolt.adapter.socket_mode"))
sys.modules.setdefault("slack_bolt.adapter.socket_mode.async_handler", adapter_stub)

import httpx
httpx_stub = types.ModuleType("httpx")
httpx_stub.AsyncClient = httpx.AsyncClient
sys.modules.setdefault("httpx", httpx_stub)

# Patch env vars required at import time
os.environ.setdefault("SLACK_BOT_TOKEN", "xoxb-test")
os.environ.setdefault("SLACK_SIGNING_SECRET", "test-secret")
os.environ.setdefault("SLACK_APP_TOKEN", "xapp-test")

sys.path.insert(0, str(__import__("pathlib").Path(__file__).parent.parent))
import bot  # noqa: E402


# ── _authorize ────────────────────────────────────────────────────────────────

def test_authorize_allow_all_when_empty():
    """Empty SLACK_ALLOWED_USERS means everyone is permitted."""
    original = bot.ALLOWED_USERS
    try:
        bot.ALLOWED_USERS = frozenset()
        assert bot._authorize("U999ANY") is True
    finally:
        bot.ALLOWED_USERS = original


def test_authorize_allow_list_passes():
    original = bot.ALLOWED_USERS
    try:
        bot.ALLOWED_USERS = frozenset(["U001", "U002"])
        assert bot._authorize("U001") is True
    finally:
        bot.ALLOWED_USERS = original


def test_authorize_allow_list_blocks():
    original = bot.ALLOWED_USERS
    try:
        bot.ALLOWED_USERS = frozenset(["U001"])
        assert bot._authorize("U999") is False
    finally:
        bot.ALLOWED_USERS = original


# ── _snap_age_days ────────────────────────────────────────────────────────────

def test_snap_age_days_recent():
    now = datetime.now(tz=timezone.utc)
    snap = {"created_at": now.isoformat().replace("+00:00", "Z")}
    age = bot._snap_age_days(snap)
    assert age < 0.01  # less than ~15 minutes old


def test_snap_age_days_old():
    old = datetime.now(tz=timezone.utc) - timedelta(days=10)
    snap = {"created_at": old.isoformat().replace("+00:00", "Z")}
    age = bot._snap_age_days(snap)
    assert 9.9 < age < 10.1


def test_snap_age_days_missing_field():
    assert bot._snap_age_days({}) == 0.0


# ── _resolve_droplet ──────────────────────────────────────────────────────────

def test_resolve_droplet_by_id():
    droplets = [{"id": 123, "name": "web"}, {"id": 456, "name": "db"}]
    result = bot._resolve_droplet(droplets, "123")
    assert result["name"] == "web"


def test_resolve_droplet_by_name():
    droplets = [{"id": 123, "name": "web"}, {"id": 456, "name": "db"}]
    result = bot._resolve_droplet(droplets, "db")
    assert result["id"] == 456


def test_resolve_droplet_not_found():
    droplets = [{"id": 123, "name": "web"}]
    assert bot._resolve_droplet(droplets, "missing") is None


# ── list_snapshots / list_droplets ────────────────────────────────────────────

@pytest.mark.asyncio
async def test_list_snapshots_empty():
    with patch.object(bot, "run_doctl", new=AsyncMock(return_value=(0, "", ""))):
        result = await bot.list_snapshots()
    assert result == []


@pytest.mark.asyncio
async def test_list_snapshots_ok():
    payload = json.dumps([{"id": "snap-1", "name": "test-snapshot-20260101-0000"}])
    with patch.object(bot, "run_doctl", new=AsyncMock(return_value=(0, payload, ""))):
        result = await bot.list_snapshots()
    assert len(result) == 1
    assert result[0]["name"] == "test-snapshot-20260101-0000"


@pytest.mark.asyncio
async def test_list_droplets_ok():
    payload = json.dumps([{"id": 999, "name": "my-droplet", "status": "active"}])
    with patch.object(bot, "run_doctl", new=AsyncMock(return_value=(0, payload, ""))):
        result = await bot.list_droplets()
    assert result[0]["id"] == 999


@pytest.mark.asyncio
async def test_list_snapshots_doctl_error():
    with patch.object(bot, "run_doctl", new=AsyncMock(return_value=(1, "", "error"))):
        result = await bot.list_snapshots()
    assert result == []


# ── delete_snapshot ───────────────────────────────────────────────────────────

@pytest.mark.asyncio
async def test_delete_snapshot_calls_correct_args():
    mock_run = AsyncMock(return_value=(0, "", ""))
    with patch.object(bot, "run_doctl", new=mock_run):
        await bot.delete_snapshot("snap-42")
    mock_run.assert_called_once_with(
        "compute", "snapshot", "delete", "snap-42", "--force"
    )


# ── _prune_snapshots ──────────────────────────────────────────────────────────

@pytest.mark.asyncio
async def test_prune_snapshots_disabled_when_no_env(monkeypatch):
    """_prune_snapshots does nothing when retention env vars are not set."""
    monkeypatch.delenv("SNAPSHOT_RETENTION_DAYS", raising=False)
    monkeypatch.delenv("SNAPSHOT_RETENTION_COUNT", raising=False)
    mock_client = MagicMock()
    # Should return immediately without calling list_snapshots or delete_snapshot
    with patch.object(bot, "list_snapshots", new=AsyncMock()) as mock_list:
        await bot._prune_snapshots("my-droplet", mock_client, "C123", "ts1")
        mock_list.assert_not_called()


@pytest.mark.asyncio
async def test_prune_snapshots_by_count(monkeypatch):
    """Keep only 2 most recent — should delete the 3 oldest."""
    monkeypatch.setenv("SNAPSHOT_RETENTION_COUNT", "2")
    monkeypatch.delenv("SNAPSHOT_RETENTION_DAYS", raising=False)

    now = datetime.now(tz=timezone.utc)
    snaps = [
        {"id": str(i), "name": f"web-snapshot-{i}",
         "created_at": (now - timedelta(days=i)).isoformat().replace("+00:00", "Z")}
        for i in range(5)
    ]

    mock_client = AsyncMock()
    mock_client.chat_postMessage = AsyncMock()

    delete_calls = []

    async def fake_delete(snap_id):
        delete_calls.append(snap_id)
        return (0, "", "")

    with patch.object(bot, "list_snapshots", new=AsyncMock(return_value=snaps)), \
         patch.object(bot, "delete_snapshot", new=fake_delete):
        await bot._prune_snapshots("web", mock_client, "C123", "ts1")

    assert len(delete_calls) == 3
    # ids 2, 3, 4 should be deleted (oldest 3 of 5)
    assert set(delete_calls) == {"2", "3", "4"}


@pytest.mark.asyncio
async def test_prune_snapshots_by_days(monkeypatch):
    """Delete snapshots older than 5 days."""
    monkeypatch.setenv("SNAPSHOT_RETENTION_DAYS", "5")
    monkeypatch.delenv("SNAPSHOT_RETENTION_COUNT", raising=False)

    now = datetime.now(tz=timezone.utc)
    snaps = [
        {"id": "new", "name": "web-snapshot-new",
         "created_at": (now - timedelta(days=1)).isoformat().replace("+00:00", "Z")},
        {"id": "old1", "name": "web-snapshot-old1",
         "created_at": (now - timedelta(days=10)).isoformat().replace("+00:00", "Z")},
        {"id": "old2", "name": "web-snapshot-old2",
         "created_at": (now - timedelta(days=20)).isoformat().replace("+00:00", "Z")},
    ]

    mock_client = AsyncMock()
    mock_client.chat_postMessage = AsyncMock()
    delete_calls = []

    async def fake_delete(snap_id):
        delete_calls.append(snap_id)
        return (0, "", "")

    with patch.object(bot, "list_snapshots", new=AsyncMock(return_value=snaps)), \
         patch.object(bot, "delete_snapshot", new=fake_delete):
        await bot._prune_snapshots("web", mock_client, "C123", "ts1")

    assert set(delete_calls) == {"old1", "old2"}
    assert "new" not in delete_calls
