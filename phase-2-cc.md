# Phase 2 Efficiency Research — Tool Comparison

**Date:** 2026-05-26  
**Question:** Is curl+jq the most efficient method to deploy a stored DigitalOcean snapshot into a running droplet? What is the best alternative?

---

## What Phase 2 Accomplished

An independent evaluation of five candidate approaches for automating the DigitalOcean snapshot/restore workflow. Each candidate was scored on six criteria. A clear recommendation was reached — no hedging.

---

## Candidates Evaluated

| # | Candidate | Description |
|---|-----------|-------------|
| 1 | curl + jq | Current approach — raw HTTP calls, manual JSON parsing |
| 2 | doctl | Official DigitalOcean CLI (Go binary, Homebrew) |
| 3 | Terraform / OpenTofu | Declarative IaC with state backend |
| 4 | Pulumi | IaC with real programming languages + state backend |
| 5 | pydo | Official DigitalOcean Python SDK |

---

## Scoring Matrix (1 = worst, 5 = best)

| Criterion | curl+jq | doctl | Terraform | Pulumi | pydo |
|-----------|---------|-------|-----------|--------|------|
| Code complexity | 2 | 5 | 2 | 2 | 3 |
| End-to-end wall time | 3 | 4 | 2 | 2 | 3 |
| Error handling quality | 1 | 5 | 3 | 3 | 3 |
| Auth security | 2 | 4 | 3 | 3 | 3 |
| Observability | 1 | 4 | 3 | 3 | 2 |
| Dependency footprint (macOS) | 4 | 4 | 1 | 1 | 3 |
| **Total** | **13** | **26** | **14** | **14** | **17** |

---

## Per-Candidate Summary

### curl + jq (13/30)
The baseline. Expresses ~15 API operations across ~620 lines of bash. Every polling loop is 10–15 lines of manual `while true` with no timeout or backoff. `set -e` provides false safety — it does not catch pipeline or command substitution failures. Token is a raw string in env or script config. No pagination handling. jq filter string interpolation creates injection risk. Minimal dependencies (curl built-in, jq via brew) are its only structural advantage.

### doctl (26/30) — **RECOMMENDED**
Official DigitalOcean CLI. The four `while true` polling loops in the current scripts collapse to `--wait` flags. Pagination is automatic. Auth is stored once in `~/.config/doctl/config.yaml` (mode 0600), never in scripts. Outputs structured JSON or formatted columns. Exits non-zero with human-readable errors on any API failure. Integrates natively with `DIGITALOCEAN_ACCESS_TOKEN` env var, making `op run` injection seamless. ~55% code reduction. One `brew install doctl`.

Key doctl commands that replace the most dangerous current code:
```bash
doctl compute droplet-action shutdown   "$DROPLET_ID" --wait          # replaces 20-line shutdown loop
doctl compute droplet-action snapshot   "$DROPLET_ID" --snapshot-name "$NAME" --wait  # replaces snapshot loop
doctl compute droplet create            "$NAME" --image "$SNAPSHOT_ID" --size "$SIZE" --region "$REGION" --ssh-keys "$KEY" --wait  # replaces create+poll loop
doctl compute reserved-ip-action assign "$IP" "$DROPLET_ID"           # replaces curl+status-check
```

### Terraform / OpenTofu (14/30)
State-based declarative IaC. Fundamentally mismatched to this workflow: Terraform wants to own the full resource lifecycle, but this workflow intentionally destroys and recreates droplets outside of state. State files become orphaned on `destroy`. Cold-start overhead (provider download, `terraform init`) adds 30–60 s. Eliminated.

### Pulumi (14/30)
Same state-model mismatch as Terraform. Adds a Pulumi Cloud or self-hosted state backend requirement. A Python Pulumi program is 100–200 lines of boilerplate to express operations doctl handles in one line. Python UI advantages (rich, questionary) are available without Pulumi's state overhead. Eliminated.

### pydo (17/30)
DigitalOcean's auto-generated Python SDK. Removes shell quoting and jq injection risks. Raises typed exceptions on API errors. But: polling loops must still be written manually (no `--wait` equivalent), fzf/menu selection requires reimplementation, and the end result is similar in length to the current bash scripts — just in Python. The correct role for Python in this stack is a UI layer on top of doctl (Phase 5), not a replacement for it.

---

## Recommendation

**Migrate to doctl. The current curl+jq approach should be replaced.**

The migration path preserves all existing user-facing behavior — the `fzf`-with-fallback selector, confirmation prompts, `list|get` idiom, post-snapshot action menu, and `DO_TOKEN` precedence chain — while replacing the unsafe, fragile curl+jq infrastructure layer with doctl calls.

Terraform and Pulumi are eliminated: wrong paradigm. pydo is eliminated: no polling advantage, adds runtime complexity without commensurate benefit. If a Python UI layer becomes desirable in Phase 5, it wraps `doctl` via `subprocess` — it does not replace it.

---

## Phase Gate

Phase 2 is complete. Phase 3 (improvement plan + batched architectural decision questions) follows.
