# AI Work Log — snaprestore

Entries are prepended — most recent first.

---
## 2026-05-27 — Session 7 (Claude Code — main)

**Focus:** Debug and fix the live Slack bot; extend /do-restore and do-restore.sh with new features; clean up repo.

### Files changed

| File | Action | Commit |
|------|--------|--------|
| `slack-bot/bot.py` | Modified — fix /do-restore size_slug, fix duplicate action_id, replace buttons with static_select dropdowns, remove 5-snapshot caps, add /do-help | `f895a2f` |
| `slack-bot/manifest.yml` | Modified — register /do-help slash command | `f895a2f` |
| `do-restore.sh` | Modified — add --auto-destroy flag, _parse_duration helper, interactive auto-destroy prompt with presets, auto-destroy background job, updated panels and JSON output | `f895a2f` |
| `README.md` | Modified — full Slack command list, auto-destroy docs, manifest update note, typical workflow updated | `fa1775a` |
| `slack-bot/uv.lock` | Added — track exact dependency lockfile for reproducible deploys | `256ec4f` |
| `prompt-01.md` | Deleted — scratch file | `256ec4f` |
| `ai_status.json` | Updated — session 7 state | this handoff |
| `AI_WORK_LOG.md` | Prepended session 7 entry | this handoff |

### Commands run

```bash
# Fix and deploy bot fixes iteratively
rsync -av -e "ssh -i ~/.ssh/id_m3do" slack-bot/bot.py dosnap@104.236.56.16:/opt/do-snap-bot/
ssh -i ~/.ssh/id_m3do root@104.236.56.16 "systemctl restart do-snap-bot"

# Commit and push
git add do-restore.sh slack-bot/bot.py slack-bot/manifest.yml
git commit -m "feat: fix /do-restore, add dropdown pickers, /do-help, and auto-destroy"
git push origin next

git add README.md
git commit -m "docs: update README with full Slack command list, auto-destroy, and bot fixes"
git push origin next

# Merge next → main (first pass, pre-uv.lock)
git checkout main && git merge --no-ff next && git push origin main

# uv.lock + prompt-01.md cleanup
git checkout next
rm prompt-01.md && git add -f slack-bot/uv.lock
git commit -m "chore: track slack-bot/uv.lock, remove prompt-01.md"
git push origin next

# Final merge and branch cleanup
git checkout main && git merge --no-ff next && git push origin main
git branch -d next && git push origin --delete next
```

### Validations
- Bot deployed and restarted successfully: pass (systemctl status active on each deploy)
- Block Kit dropdown fix: pass (confirmed via live Slack test — /do-restore showed snapshot picker)
- Bash syntax check (do-restore.sh): pass (`bash -n` returned OK)
- Unit tests: not run this session

### Outcome
Fixed two blocking bugs in the live Slack bot: (1) `/do-restore` was failing with "Droplet creation failed" because the hardcoded `s-1vcpu-1gb` size slug has a 25 GB disk ceiling — now auto-selects the smallest slug satisfying the snapshot's `min_disk_size`; (2) the snapshot selection UI was broken with a Block Kit `invalid_blocks` error caused by duplicate `action_id` values across buttons — replaced with a `static_select` dropdown supporting up to 100 options. Removed the 5-snapshot cap from all three pickers, added `/do-help`, and implemented `--auto-destroy` in `do-restore.sh` with both a flag and an interactive preset picker. All changes merged to main; branch `next` deleted.

### Next step
Apply the updated Slack app manifest to register /do-help: open https://api.slack.com/apps → DO Snap Bot → App Manifest → YAML tab → paste contents of slack-bot/manifest.yml → Save Changes.

---
## 2026-05-27 — Session 6 (Antigravity — next)

**Focus:** Implement all PARKING_LOT Slack commands, Block Kit restore selection, background scheduling & snapshot retention, and add robust tests.

### Files changed

| File | Action | Commit |
|------|--------|--------|
| `docs/PARKING-implementation-plan.md` | Created — engineering design plan for the feature set | `15c41dc` |
| `slack-bot/bot.py` | Modified — implemented 9 new slash commands, interactive snapshot restore picker, background scheduled snapshots, and pruning retention logic | `15c41dc` |
| `slack-bot/manifest.yml` | Modified — updated Slack app manifest with interactivity fix and 9 new slash command definitions | `15c41dc` |
| `slack-bot/.env.op.example` | Modified — added retention and scheduled snapshot variables | `15c41dc` |
| `docs/commands.md` | Modified — added reference guide for the 9 new slash commands | `15c41dc` |
| `slack-bot/README-slack-bot.md` | Modified — documented scheduling/retention parameters and all new commands | `15c41dc` |
| `slack-bot/pyproject.toml` | Modified — added `dev` optional dependency group with pytest & pytest-asyncio | `15c41dc` |
| `slack-bot/tests/test_bot.py` | Created — added 17 asynchronous unit tests for bot.py's command and helper logic | `15c41dc` |
| `docs/next-steps.md` | Created — added complete 4-part deployment, verification, and rollback guide | `ea9fe7a` |
| `ai_status.json` | Updated — reflected session accomplishments and next steps | this handoff |
| `AI_WORK_LOG.md` | Prepended session 6 entry | this handoff |

### Commands run

```bash
git checkout -b next
git status
pip install -e ".[dev]"
pytest
git add docs/PARKING-implementation-plan.md slack-bot/bot.py slack-bot/manifest.yml slack-bot/.env.op.example docs/commands.md slack-bot/README-slack-bot.md slack-bot/pyproject.toml slack-bot/tests/test_bot.py
git commit -m "feat(bot): implement Slack commands & bot improvements from PARKING_LOT"
git add docs/next-steps.md
git commit -m "docs: add next-steps.md — Slack manifest + controller deployment guide"
git push origin next
```

### Validations
- Asynchronous Unit Tests (slack-bot/tests/test_bot.py): pass (17/17 passed)
- Ruff Linting: pass (no issues found)

### Outcome
Implemented 9 new slash commands covering droplet management, reserved IP assignment, and snapshot details. Redesigned `/do-restore` command to offer interactive confirmation buttons for snapshot selection using Slack Block Kit. Added a background snapshot scheduler and a retention policy manager to prune older snapshots automatically. Verified all core bot logic via a comprehensive test suite of 17 passing unit tests. Pushed all changes to branch `next` and wrote a complete, step-by-step deployment guide (`docs/next-steps.md`).

### Next step
Apply the updated Slack app manifest: open https://api.slack.com/apps → DO Snap Bot → App Manifest → YAML tab → paste contents of slack-bot/manifest.yml → Save. Then follow docs/next-steps.md Part 2 to rsync and restart the bot on the controller.

---
## 2026-05-27 — Session 5 (Claude Code — main)

**Focus:** CLAUDE.md, remove setup-op-fix.md from repo, README fully updated.

### Files changed

| File | Action | Commit |
|------|--------|--------|
| `CLAUDE.md` | Created — full Claude Code context for new sessions | `68960d7` |
| `docs/setup-op-fix.md` | Removed from git tracking (`git rm --cached`); added to `.gitignore` | `643b9b2` |
| `.gitignore` | Added `docs/setup-op-fix.md` entry | `643b9b2` |
| `README.md` | Scrubbed setup-op-fix reference; then full update pass | `643b9b2`, `bff240c` |
| `CLAUDE.md` | Scrubbed setup-op-fix reference | `643b9b2` |
| `docs/setup.md` | Replaced setup-op-fix link with plain prose | `643b9b2` |
| `docs/troubleshooting.md` | Replaced two setup-op-fix links with plain prose | `643b9b2` |
| `ai_status.json` | Updated | this handoff |
| `AI_WORK_LOG.md` | Prepended session 5 entry | this handoff |

### Commands run

```bash
git status --short
git log -n 5 --oneline
grep -rn "setup-op-fix" . --include="*.md" --include="*.sh" --include="*.py"
git rm --cached docs/setup-op-fix.md
git add .gitignore README.md CLAUDE.md docs/setup.md docs/troubleshooting.md
git commit -m "Remove setup-op-fix.md from repo; add to .gitignore; scrub references"
git push origin main
git add README.md
git commit -m "update: README — scopes, Slack bot features, new docs, file structure"
git push origin main
git branch -d next-cc
git push origin --delete next-cc
```

### Validations

- `CLAUDE.md` accuracy vs actual repo state: pass — reviewed against all key files before writing
- All setup-op-fix.md references removed: pass — grep confirmed zero remaining
- `/do-restore` Slack end-to-end (nginx + health check): not run
- nginx welcome page renders at restored IP: not run
- `./do-snapshot.sh` bash script: not run this session
- `./do-restore.sh` bash script: not run this session

### Outcome

Session was a documentation and housekeeping pass. `CLAUDE.md` gives any new Claude Code session immediate orientation: architecture, security rules, bot internals, 1Password paths, deploy commands, pitfall table, and handoff pointers. `setup-op-fix.md` (contained a draft IT email) removed from GitHub history going forward — file preserved locally, `.gitignore` prevents re-addition. README brought fully up to date: `image:read` scope added, `uv` in requirements, all four new docs in the table, Slack bot interactive features described, Slack workflow section added. Repo is clean on `main` at `bff240c`.

### Next step

Run `/do-restore <snapshot-id>` in Slack to verify end-to-end: droplet creates, nginx welcome page loads at the new IP, health check result posts back to the Slack thread.

---
## 2026-05-27 — Session 4 (Claude Code — main)

**Focus:** Interactive Slack confirmations, nginx welcome page, reference docs, branch cleanup.

### Files changed

| File | Action | Commit |
|------|--------|--------|
| `slack-bot/bot.py` | Added interactive Block Kit shutdown/restart confirmations to snapshot flow; wired nginx welcome page cloud-init into restore flow | `018cb24` |
| `docs/snaprestore-viz.md` | Created — ASCII architecture diagrams | `018cb24` |
| `docs/slack-integration-options.md` | Created — snapshot delete commands, Slack connection modes, free controller alternatives | `018cb24` |
| `docs/benchmarks-speed-tests.md` | Created — timing methodology, ranges, comparison table, benchmark log template | `018cb24` |
| `docs/PARKING_LOT.md` | Created — checkbox backlog for parity, Slack commands, bot improvements | `018cb24` |
| `ai_status.json` | Updated | this handoff |
| `AI_WORK_LOG.md` | Prepended session 4 entry | this handoff |

### Commands run

```bash
git status --short
git log -n 5 --oneline
git add slack-bot/bot.py docs/PARKING_LOT.md docs/benchmarks-speed-tests.md docs/slack-integration-options.md docs/snaprestore-viz.md
git commit -m "Add interactive Slack confirmations, nginx welcome page, and reference docs"
git push origin main
git branch -d next-cc
git push origin --delete next-cc
rsync -av -e "ssh -i ~/.ssh/id_m3do" slack-bot/bot.py dosnap@104.236.56.16:/opt/do-snap-bot/bot.py
ssh -i ~/.ssh/id_m3do root@104.236.56.16 "systemctl restart do-snap-bot && sleep 3 && systemctl status do-snap-bot --no-pager"
```

### Validations

- `/do-snapshot` Slack command (shutdown confirmation + snapshot): pass — confirmed working in prior session
- `/do-restore` Slack command end-to-end (nginx cloud-init + health check): not run — code deployed but not tested live
- nginx welcome page renders at restored droplet IP: not run
- `./do-snapshot.sh` bash script: not run this session
- `./do-restore.sh` bash script: not run this session

### Outcome

Slack bot now has interactive Block Kit button confirmations for the snapshot flow — shutdown prompt before snapshotting (active droplets only), restart prompt after snapshot if the bot shut the droplet down. The nginx welcome page (previously stubbed but never invoked) is now wired into `_restore_job()` via a temp cloud-init file passed to `doctl compute droplet create --user-data-file`. Four reference docs added covering architecture visualization, free hosting alternatives, snapshot/restore benchmarks, and a feature backlog. `next-cc` branch deleted locally and from origin. All changes committed (`018cb24`) and pushed to main. Bot deployed and confirmed `active (running)` on controller at `104.236.56.16`.

### Next step

Run `/do-restore <snapshot-id>` in Slack to verify end-to-end: droplet creates, nginx welcome page loads at the new IP, health check posts result to the Slack thread.

---
## 2026-05-26 — Session 3 (Claude Code — next-cc)

**Focus:** No new work — consecutive `/relay-handoff` invocation immediately following session 2. Session boundary marker only.

### Files changed

| File | Action | Commit |
|------|--------|--------|
| `ai_status.json` | Updated session number, git_sha, focus, completed_this_session | this handoff |
| `AI_WORK_LOG.md` | Prepended session 3 entry | this handoff |

### Commands run

```bash
git status --short
git log -n 5 --oneline
git branch --show-current
```

### Validations

- `./do-snapshot.sh --dry-run`: not run
- `./do-restore.sh --dry-run`: not run
- Live DO API reads or writes: not run
- Slack bot local test (`./start.sh`): not run

### Outcome

No code or documentation changes this session. This entry records the session boundary only. All substantive work (docs/setup-cc.md, slack-bot/README-slack-bot.md, README.md) was completed and pushed in session 2 as commits `e0206c5` and `fe5ec0c`. Branch is clean and fully up to date with `origin/next-cc`.

### Next step

Run `./do-snapshot.sh --dry-run` to validate the full script flow against the `default` doctl context — confirms token loading, droplet fetch, fzf/ANSI selector, and dry-run path all work before any live API writes.

---
## 2026-05-26 — Session 2 (Claude Code — next-cc)

**Focus:** Comprehensive setup documentation — complete rewrite of `docs/setup-cc.md`, new `slack-bot/README-slack-bot.md`, `README.md` updates.

### Files changed

| File | Action | Commit |
|------|--------|--------|
| `docs/setup-cc.md` | Completely rewritten — 7-part setup guide (DO tokens, doctl, 1Password, env file, script testing, controller droplet, Slack app) | `e0206c5` |
| `slack-bot/README-slack-bot.md` | Created — file-by-file breakdown, architecture notes, setup with identical language to setup-cc.md Parts 6 & 7 | `e0206c5` |
| `README.md` | Added setup guide link at top, Slack bot README link in Slack Bot section, updated file structure listing | `e0206c5` |

### Commands run

```bash
git checkout next-cc
git status --short
git log -n 5 --oneline
# (file reads: docs/setup-cc.md, README.md, .env.example, slack-bot/* — all files)
git add README.md docs/setup-cc.md slack-bot/README-slack-bot.md
git commit -m "Add comprehensive setup docs and slack-bot README"
git push origin next-cc
```

### Validations

- Commit `e0206c5` pushed to `origin/next-cc`: pass
- All `op://` paths in new docs match `.env.example` and `.env.op.example` defaults: pass (verified by cross-reading files)
- Identical language in setup-cc.md Parts 6 & 7 vs README-slack-bot.md setup sections: pass (written from same source)
- `./do-snapshot.sh --dry-run`: not run
- `./do-restore.sh --dry-run`: not run
- Live DO API reads or writes: not run
- Slack bot local test (`./start.sh`): not run

### Outcome

`docs/setup-cc.md` is now a complete, standalone setup guide for new users — covering every step from DO token creation through live script testing and Slack bot deployment. `slack-bot/README-slack-bot.md` is a new file that explains every item in the `slack-bot/` directory and reuses identical step-by-step language from `setup-cc.md` for the controller droplet and Slack app sections. `README.md` now links to both new docs files and has an accurate file structure listing. Branch is clean and pushed. Scripts remain untested at the CLI level.

### Next step

Run `./do-snapshot.sh --dry-run` to validate the full script flow against the `default` doctl context — confirms token loading, droplet fetch, fzf/ANSI selector, and dry-run path all work before any live API writes.

---
## 2026-05-26 — Session 1 (Claude Code — next-cc)

**Focus:** Canonical file renames, `.env.example`, README hardening, new-user setup doc on `next-cc`.

### Files changed

| File | Action | Commit |
|------|--------|--------|
| `README_md.md` → `README.md` | Renamed via git mv | `d9f298b` |
| `do-snapshot_sh.sh` → `do-snapshot.sh` | Renamed via git mv, chmod +x, DOCTL_CONTEXT wired | `d9f298b` |
| `do-restore_sh.sh` → `do-restore.sh` | Renamed via git mv, chmod +x, DOCTL_CONTEXT wired | `d9f298b` |
| `phase-1-cc.md` | Deleted | `d9f298b` |
| `phase-2-cc.md` | Deleted | `d9f298b` |
| `.env.example` | Created — all variables with op:// examples, four sections | `d9f298b` |
| `.gitignore` | Added `!.env.example` exception | `d9f298b` |
| `README.md` | Added setup step 4 (env file), updated op run example, expanded file tree | `d9f298b` |
| `docs/setup-cc.md` | Created — new-user setup guide for next-cc | `d9f298b` |
| `ai_status.json` | Created — Relay handoff state | this handoff |
| `AI_WORK_LOG.md` | Created — this file | this handoff |

### Commands run

```bash
git checkout next-cc
git status
find . -maxdepth 2 -not -path './.git/*' -not -path './.omx/*' | sort
chmod +x do-snapshot.sh do-restore.sh
git mv README_md.md README.md
git mv do-snapshot_sh.sh do-snapshot.sh
git mv do-restore_sh.sh do-restore.sh
git rm phase-1-cc.md phase-2-cc.md
git add .gitignore README.md do-snapshot.sh do-restore.sh .env.example docs/
git commit -m "Rename files, add .env.example, update README, add docs/setup-cc.md"
git push origin next-cc
git status --short
git log -n 5 --oneline
doctl auth list
ls -la do-snapshot.sh do-restore.sh
```

### Validations

- Git rename / delete operations completed cleanly: pass
- `.env.example` reviewed — no literal tokens present: pass
- `git push origin next-cc` succeeded (`d9f298b`): pass
- `./do-snapshot.sh --dry-run`: not run
- `./do-restore.sh --dry-run`: not run
- `bash -n` / `shellcheck` on scripts: not run
- Live DO API reads or writes: not run

### Outcome

All file naming debt on `next-cc` is resolved: scripts and README now have canonical names, phase docs are gone, `.env.example` documents every variable with `op://` examples and is tracked (`.gitignore` exemption in place). Both scripts are executable and wired to the `default` doctl context so they run without an interactive token prompt. A new-user setup guide lives in `docs/setup-cc.md`. Branch is clean and pushed.

### Next step

Run `./do-snapshot.sh --dry-run` to validate the full script flow against the `default` doctl context — confirms token loading, droplet fetch, fzf/ANSI selector, and dry-run path all work before any live API writes.
