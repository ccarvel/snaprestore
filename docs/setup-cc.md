# New User Setup (next-cc branch)

## What was missing (now fixed)

- Scripts weren't executable → `chmod +x` done
- `DOCTL_CONTEXT=""` → set to `"default"` in both scripts (your existing `doctl` context)

---

## Your environment

| Tool | Status |
|------|--------|
| `doctl` | ✓ installed, `default` context active |
| `jq` | ✓ installed |
| `fzf` | ✓ installed (arrow-key menus will work) |
| `gum` | not installed — bootstrap will offer to `brew install gum` on first run |

---

## Test with dry-run

No API writes, but does read your droplets/snapshots:

```bash
./do-snapshot.sh --dry-run
./do-restore.sh --dry-run
```

The first run will ask if you want to install `gum`. Say yes for the rich UI, or no to use the built-in ANSI fallback — either way the script proceeds fully.

**List your droplets/snapshots without doing anything:**

```bash
DROPLET_ID=list ./do-snapshot.sh     # exits after listing droplets
SNAPSHOT_ID=list ./do-restore.sh     # exits after listing snapshots
```

---

## If you later want a dedicated context instead of `default`

```bash
doctl auth init --context snaprestore   # paste your DO token, scoped per README
```

Then change `DOCTL_CONTEXT="default"` → `"snaprestore"` in both config blocks. The dedicated context keeps the narrower-scoped token separate from your general-purpose one.
