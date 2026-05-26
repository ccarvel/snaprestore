# Phase 1 Audit — do-snapshot.sh / do-restore.sh

**Date:** 2026-05-26  
**Files audited:** `do-snapshot.sh`, `do-restore.sh`, `README.md`  
**Method:** Three-pass read of each file (structure → external commands/API calls/input points → error paths/polling loops/silent failures), then structured analysis across five categories.

---

## What Phase 1 Accomplished

A full security, stability, efficiency, correctness, and UX audit of the two DigitalOcean snapshot/restore scripts. 27 substantive findings were identified with specific line citations. Findings are ranked by severity below.

---

## Findings Summary

### Critical (2)

| ID | File | Lines | Issue |
|----|------|-------|-------|
| E1 | both | snap:154,197,250 / restore:276 | Four `while true` polling loops with no timeout, no iteration cap, no elapsed-time display. A stuck DO action hangs the terminal indefinitely. |
| S1 | both | snap:41 / restore:45 | `read -p` used for token entry — no `-s` flag, so token is echoed to terminal in plaintext and captured in scrollback/history. |

### High (9)

| ID | File | Lines | Issue |
|----|------|-------|-------|
| E2 | both | snap:2 / restore:2 | `set -e` does not protect pipeline failures (`curl \| jq`), command substitutions (`$(…)`), or loop conditions. Silent failure on network error leaves null variables in play. |
| E3 | both | all curl calls | No `--connect-timeout` or `--max-time` on any curl call. Network stalls hang indefinitely before even reaching the polling loops. |
| E4 | snapshot | 162–169 | After graceful shutdown reports `errored`, script fires `power_off` but discards the action ID, sleeps 10 s, and proceeds straight to snapshot — never verifying the droplet is actually off. Snapshot of a live droplet risks filesystem inconsistency. |
| E5 | both | snap:65 / restore:119,150,178,210 | All interactive selection arrays are built with unquoted `$(…)` word splitting. Any droplet/snapshot name containing a space corrupts the array and breaks every subsequent `cut -d'\|' -f1` parse. |
| S3 | both | snap:185 / restore:257 | `SNAPSHOT_NAME` and `DROPLET_NAME` are interpolated directly into the `-d` JSON payload without sanitization. A name containing `"` malforms the JSON; a name containing `$(…)` is shell-evaluated before curl receives it. |
| S4 | both | snap:77,92 / restore:72 | `DROPLET_ID` is injected raw into jq filter strings (`".droplets[] \| select(.id == $DROPLET_ID)"`). Should use `--argjson id "$DROPLET_ID"` with `select(.id == $id)`. |
| A1 | both | snap:60 / restore:114 | DO API returns max 200 records per page; no pagination loop or link-header following. Users with >200 snapshots/droplets see only the first page with no warning. |
| W1 | restore | 299–302 | If `RESERVED_IP` is hardcoded, its region is never validated against the snapshot region. Assignment silently fails with 422 after the droplet is already running. |
| S2 | both | snap:7 / restore:7 | Config block design and README examples encourage hardcoding the token directly in the script, increasing the risk of it being committed to version control. |
| U1 | both | all loops | No elapsed-time counter in any polling loop. User cannot distinguish "still working" from "hung" during a 30-minute snapshot operation. |

### Medium (8)

| ID | File | Lines | Issue |
|----|------|-------|-------|
| E6 | snapshot | 286–290 | `curl -w "%{http_code}"` appends status code after response body in the same variable. On errors, `$DELETE_RESPONSE` is `{json body}404` — the string equality check `= "204"` fails but error output shows the full blob, not just the code. |
| E7 | both | — | No `trap SIGINT SIGTERM` handler. Ctrl-C mid-operation leaves the user with no indication of what state the remote resources are in. |
| W2 | snapshot | 218 | Post-snapshot ID is looked up by name match. Duplicate snapshot names (retried run) cause jq to emit two concatenated objects; `NEW_SNAPSHOT_ID` captures only the last. Should capture ID from the creation action response instead. |
| W3 | restore | 304–310 | Reserved IP assignment reports "assigned successfully!" when status is `in-progress`, not `completed`. User may SSH to the reserved IP before assignment finishes and get connection refused. |
| S5 | both | snap:148 / restore error paths | API error responses echoed unredacted to stdout, including droplet IDs and IP addresses. |
| S6 | restore | 299–302 | No confirmation prompt before reassigning a reserved IP. Silently reassigning a live IP away from another production droplet would break it instantly. |
| A2 | restore | 70–71,114 | `/v2/snapshots` endpoint fetched twice in the restore flow: once inside `list_sizes()` and again in the main interactive path. |
| U2 | both | all curl calls | Single-shot API calls print only a static `Fetching…` line with no spinner or activity indicator. On slow connections these stall silently. |
| U3 | snapshot | 292–294 | Post-delete summary shows only snapshot name and ID. Missing: restore command, snapshot size, min disk requirement, estimated storage cost. |

### Low (8)

| ID | File | Lines | Issue |
|----|------|-------|-------|
| W4 | restore | 151 | `min_disk_size` is locked to the source droplet's total disk, not actual used space. A 160 GB disk with 5 GB used produces `min_disk_size: 160`, permanently locking the user into large (expensive) droplets. |
| W5 | restore | 192–196 | SSH key JSON assembled via fragile `sed` chain. Breaks on fingerprint strings, quoted IDs, or space-separated input. |
| A3 | both | snap:78–86 / restore:132–135 | Seven (snapshot) and four (restore) separate `echo "$VAR" \| jq` calls on the same in-memory blob. Should be collapsed into one jq call emitting newline-separated values. |
| A4 | snapshot | 45–49,60 | `list_droplets()` helper issues its own curl call and exits immediately; main flow issues an identical call. Functions duplicate logic instead of reusing the already-fetched `$DROPLETS`. |
| E8 | both | snap:119,128 / restore:175,203,227,245 | All `read -p` calls omit `-r`. A backslash in user input (snapshot name, confirmation) is consumed rather than treated as a literal character. |
| U4 | both | snap:22 / restore:26 | `fzf` invoked with no `--preview`, `--header`, or `--bind`. Size selection especially would benefit from a preview panel showing CPU/RAM/disk/price. |
| U5 | both | — | No `--dry-run` mode. Given the destructive delete path, dry-run is important for safe automation. |
| S_README | README | 52–54,98–99 | README shows live token strings in pre-configured examples (`DO_TOKEN="dop_v1_xxxx"`). Should reference environment variable or secret manager instead. |

---

## Five-Category Summary

| Category | Critical | High | Medium | Low |
|----------|---------|------|--------|-----|
| Security posture | 1 | 3 | 2 | 1 |
| Stability / error handling | 1 | 4 | 2 | 1 |
| API efficiency | 0 | 1 | 1 | 2 |
| Workflow correctness | 0 | 1 | 2 | 2 |
| UX gaps | 0 | 1 | 2 | 2 |

**Total: 27 findings** — 2 Critical, 10 High, 9 Medium, 6 Low.

---

## Phase Gate

Phase 1 is complete. Phase 2 (efficiency research: curl/jq vs doctl vs Terraform vs Pulumi vs pydo) begins next.
