#!/usr/bin/env bash
# lib/ui.sh — Unified UI layer for do-snap-tool.
# Sourced after bootstrap.sh has set UI_MODE=gum|richpy|ansi.
#
# Public interface (same across all modes):
#   ui_banner TITLE
#   ui_header TITLE
#   ui_panel  TITLE  KEY VAL [KEY VAL ...]
#   ui_info   MSG
#   ui_ok     MSG
#   ui_warn   MSG
#   ui_err    MSG
#   ui_confirm PROMPT [default_Y|N]  → exit 0 (yes) / 1 (no)
#   ui_input   PROMPT DEFAULT        → echoes result
#   ui_input_secret PROMPT           → echoes result (hidden entry)
#   ui_choose  PROMPT OPTION...      → echoes selected option
#   ui_spinner_start TITLE [eta_secs]
#   ui_spinner_stop  [ok_message]
#   get_eta    ACTION [disk_gb]      → echoes estimated seconds or ""
#   record_duration ACTION SECONDS [disk_gb]

[[ -n "$_DO_SNAP_UI" ]] && return 0
export _DO_SNAP_UI=1

# ── constants ─────────────────────────────────────────────────────────────────

_UI_W=76
_HISTORY="${HOME}/.config/do-snap-tool/history.jsonl"

# fzf detection (shared by all modes)
HAS_FZF=$(command -v fzf &>/dev/null && echo "yes" || echo "no")
export HAS_FZF

# ── spinner — shared across all UI modes ──────────────────────────────────────

_SPINNER_PID=""
_SPINNER_START=0

ui_spinner_start() {
  local title="$1"
  local eta_secs="${2:-0}"

  [[ "$QUIET" == true ]] && return 0

  # Hide cursor while spinning
  [[ -z "$NO_COLOR" && -t 1 ]] && tput civis 2>/dev/null || true

  _SPINNER_START=$(date +%s)
  local start_ts="$_SPINNER_START"

  (
    local chars=('⣾' '⣽' '⣻' '⢿' '⡿' '⣟' '⣯' '⣷')
    local idx=0 tick=0 elapsed=0
    local SC='' TC='' EC='' R=''
    if [[ -z "$NO_COLOR" && -t 1 ]]; then
      SC=$'\e[36m'; TC=$'\e[2m'; EC=$'\e[33m'; R=$'\e[0m'
    fi
    while true; do
      (( tick % 10 == 0 )) && elapsed=$(( $(date +%s) - start_ts ))
      local m=$(( elapsed / 60 )) s=$(( elapsed % 60 ))
      local ts; printf -v ts '%02d:%02d' "$m" "$s"
      local eta_str=""
      if (( eta_secs > 0 )); then
        local rem=$(( eta_secs - elapsed ))
        if (( rem > 0 )); then
          local rm=$(( rem / 60 )) rs=$(( rem % 60 ))
          printf -v eta_str ' · %sETA %02d:%02d%s' "$EC" "$rm" "$rs" "$R"
        fi
      fi
      printf '\r  %s%s%s  %s  %s%s%s%s%*s' \
        "$SC" "${chars[$idx]}" "$R" \
        "$title" \
        "$TC" "$ts" "$eta_str" "$R" \
        10 ""
      idx=$(( (idx + 1) % 8 ))
      (( tick++ ))
      sleep 0.1
    done
  ) &
  _SPINNER_PID=$!
  disown "$_SPINNER_PID" 2>/dev/null || true
}

ui_spinner_stop() {
  local msg="${1:-}"
  if [[ -n "$_SPINNER_PID" ]]; then
    kill "$_SPINNER_PID" 2>/dev/null || true
    wait "$_SPINNER_PID" 2>/dev/null || true
    _SPINNER_PID=""
    local cols; cols=$(tput cols 2>/dev/null || echo 80)
    printf '\r%*s\r' "$cols" ""
  fi
  [[ -z "$NO_COLOR" && -t 1 ]] && tput cnorm 2>/dev/null || true
  [[ -n "$msg" ]] && ui_ok "$msg"
}

# ── ETA history ───────────────────────────────────────────────────────────────

_ui_reverse() {
  command -v tac  &>/dev/null && { tac  "$1"; return; }
  tail -r "$1" 2>/dev/null    && return
  awk '{a[NR]=$0} END{for(i=NR;i>=1;i--) print a[i]}' "$1"
}

get_eta() {
  local action="$1" disk_gb="${2:-}"
  [[ ! -f "$_HISTORY" ]] && {
    [[ -n "$disk_gb" && "$action" == "snapshot" ]] && echo $(( disk_gb * 12 ))
    return
  }
  local sum=0 count=0
  while IFS= read -r line; do
    [[ -z "$line" ]] && continue
    local la; la=$(echo "$line" | jq -r '.action'      2>/dev/null) || continue
    [[ "$la" != "$action" ]] && continue
    if [[ -n "$disk_gb" ]]; then
      local ld; ld=$(echo "$line" | jq -r '.disk_gb // 0' 2>/dev/null) || continue
      local diff=$(( ld - disk_gb )); (( ${diff#-} > 20 )) && continue
    fi
    local dur; dur=$(echo "$line" | jq -r '.duration_s' 2>/dev/null) || continue
    sum=$(( sum + dur )); (( count++ ))
    (( count >= 5 )) && break
  done < <(_ui_reverse "$_HISTORY")
  if (( count > 0 )); then
    echo $(( sum / count ))
  elif [[ -n "$disk_gb" && "$action" == "snapshot" ]]; then
    echo $(( disk_gb * 12 ))
  fi
}

record_duration() {
  local action="$1" dur="$2" disk_gb="${3:-}"
  mkdir -p "$(dirname "$_HISTORY")"
  local ts; ts=$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date +%Y-%m-%dT%H:%M:%SZ)
  local extra=""
  [[ -n "$disk_gb" ]] && extra=",\"disk_gb\":$disk_gb"
  printf '{"ts":"%s","action":"%s","duration_s":%s%s}\n' \
    "$ts" "$action" "$dur" "$extra" >> "$_HISTORY"
}

# ══════════════════════════════════════════════════════════════════════════════
# GUM MODE
# ══════════════════════════════════════════════════════════════════════════════
if [[ "$UI_MODE" == "gum" ]]; then

ui_banner() {
  [[ "$QUIET" == true ]] && return 0
  echo ""
  gum style \
    --border double --border-foreground 14 \
    --bold --align center \
    --padding "0 4" --margin "0 2" \
    --width $(( _UI_W - 4 )) \
    "✦  $1  ✦"
  echo ""
}

ui_header() {
  [[ "$QUIET" == true ]] && return 0
  echo ""
  gum style \
    --foreground 14 --bold \
    --margin "0 2" \
    "── $1 ──"
}

ui_panel() {
  [[ "$QUIET" == true ]] && return 0
  local title="$1"; shift
  local body=""
  body+="$(gum style --bold --foreground 14 "$title")"$'\n'
  body+="$(printf '%*s' $(( _UI_W - 10 )) '' | tr ' ' '─')"$'\n'
  while [[ $# -ge 2 ]]; do
    body+="$(printf '%-18s  %s' "$1" "$2")"$'\n'
    shift 2
  done
  echo "$body" | gum style \
    --border rounded --border-foreground 14 \
    --padding "0 2" --margin "0 2" \
    --width $(( _UI_W - 4 ))
  echo ""
}

ui_info() {
  [[ "$QUIET" == true ]] && return 0
  gum style --foreground 12 --margin "0 2" "▸  $*"
}

ui_ok() {
  [[ "$QUIET" == true ]] && return 0
  gum style --foreground 10 --bold --margin "0 2" "✓  $*"
}

ui_warn() { gum style --foreground 11 --margin "0 2" "⚠  $*" >&2; }
ui_err()  { gum style --foreground 9  --bold --margin "0 2" "✗  $*" >&2; }

ui_confirm() {
  local prompt="$1" default="${2:-Y}"
  if [[ "${default,,}" == "y" ]]; then
    gum confirm --default=true  "$prompt"
  else
    gum confirm --default=false "$prompt"
  fi
}

ui_input() {
  local prompt="$1" default="$2"
  local result
  result=$(gum input \
    --placeholder "$default" \
    --prompt "  $prompt: " \
    --width $(( _UI_W - 6 )))
  echo "${result:-$default}"
}

ui_input_secret() {
  gum input --password \
    --prompt "  $1: " \
    --width $(( _UI_W - 6 ))
}

ui_choose() {
  local prompt="$1"; shift
  if [[ "$HAS_FZF" == "yes" ]]; then
    printf '%s\n' "$@" | fzf \
      --height=15 \
      --prompt="$prompt " \
      --header="↑↓ navigate  Enter select  Ctrl-C abort" \
      --border=rounded
  else
    printf '%s\n' "$@" | gum choose \
      --header "$prompt" \
      --height 10
  fi
}

fi  # end gum mode

# ══════════════════════════════════════════════════════════════════════════════
# ANSI + RICHPY MODES  (shared interactive primitives; richpy overrides panels)
# ══════════════════════════════════════════════════════════════════════════════
if [[ "$UI_MODE" == "ansi" || "$UI_MODE" == "richpy" ]]; then

# Colour codes — cleared wholesale when NO_COLOR is set or stdout is not a tty
if [[ -n "$NO_COLOR" || ! -t 1 ]]; then
  _R='' _B='' _D='' _CC='' _CG='' _CY='' _CR='' _CW=''
else
  _R=$'\e[0m' _B=$'\e[1m' _D=$'\e[2m'
  _CC=$'\e[36m' _CG=$'\e[32m' _CY=$'\e[33m' _CR=$'\e[31m' _CW=$'\e[97m'
fi

_COLS=$(tput cols 2>/dev/null || echo 80)
(( _COLS > 80 )) && _COLS=80

_hl_d() { printf "${_CC}%*s${_R}\n" "$_COLS" '' | tr ' ' '═'; }
_hl_s() { printf "${_D}%*s${_R}\n"  "$_COLS" '' | tr ' ' '─'; }

ui_info() {
  [[ "$QUIET" == true ]] && return 0
  printf "${_CC}  ▸  ${_R}%s\n" "$*"
}
ui_ok() {
  [[ "$QUIET" == true ]] && return 0
  printf "${_CG}  ✓  ${_R}%s\n" "$*"
}
ui_warn() { printf "${_CY}  ⚠  ${_R}%s\n" "$*" >&2; }
ui_err()  { printf "${_CR}  ✗  ${_R}%s\n" "$*" >&2; }

ui_confirm() {
  local prompt="$1" default="${2:-Y}"
  local hint ans
  [[ "${default,,}" == "y" ]] && hint="[Y/n]" || hint="[y/N]"
  read -rp "  ${_B}${_CC}?${_R}  $prompt $hint: " ans
  ans="${ans:-$default}"
  [[ "${ans,,}" == "y" ]]
}

ui_input() {
  local prompt="$1" default="$2" result
  read -rp "  ${_B}${_CC}?${_R}  $prompt [$default]: " result
  echo "${result:-$default}"
}

ui_input_secret() {
  local result
  read -rsp "  ${_B}${_CC}?${_R}  $1: " result
  echo
  echo "$result"
}

ui_choose() {
  local prompt="$1"; shift
  local options=("$@")
  if [[ "$HAS_FZF" == "yes" ]]; then
    printf '%s\n' "${options[@]}" | fzf \
      --height=15 \
      --prompt="$prompt " \
      --header="↑↓ navigate  Enter select  Ctrl-C abort"
  else
    echo "" >&2
    printf "${_B}${_CC}  %s${_R}\n" "$prompt" >&2
    printf "  ${_D}%*s${_R}\n" $(( _COLS - 4 )) '' | tr ' ' '─' >&2
    local i=1
    for opt in "${options[@]}"; do
      printf "    ${_CW}%2d)${_R}  %s\n" "$i" "$opt" >&2
      (( i++ ))
    done
    echo "" >&2
    local sel
    read -rp "  Enter number: " sel
    [[ -z "$sel" ]] && { ui_err "No selection made."; return 1; }
    echo "${options[$((sel - 1))]}"
  fi
}

# ── ANSI panel/banner/header (used directly in ansi mode; fallback in richpy) ─

_ansi_banner() {
  echo ""
  _hl_d
  printf "${_B}${_CC}  ▶  %-*s  v2.0${_R}\n" $(( _COLS - 10 )) "$1"
  _hl_d
  echo ""
}

_ansi_header() {
  echo ""
  printf "${_B}${_CW}  %s${_R}\n" "$1"
  _hl_s
}

_ansi_panel() {
  local title="$1"; shift
  local inner_w=$(( _COLS - 8 ))
  echo ""
  printf "  ${_CC}╭─ ${_B}%s${_R}${_CC} %s╮${_R}\n" \
    "$title" "$(printf '%*s' $(( _COLS - ${#title} - 8 )) '' | tr ' ' '─')"
  while [[ $# -ge 2 ]]; do
    printf "  ${_CC}│${_R}  ${_B}%-18s${_R}  %-*s  ${_CC}│${_R}\n" \
      "$1" $(( inner_w - 22 )) "$2"
    shift 2
  done
  printf "  ${_CC}╰%*s╯${_R}\n" $(( _COLS - 4 )) '' | tr ' ' '─'
  echo ""
}

# ── richpy mode: override panels with Python rich; keep ansi for everything else

if [[ "$UI_MODE" == "richpy" ]]; then
  _PY_CMD="uv run --quiet --with rich python3 ${SNAP_LIB_DIR}/ui_rich_py.py"

  _py_or_ansi() {   # _py_or_ansi <ansi_func> <py_cmd> [py_args...]
    local ansi_func="$1" py_subcmd="$2"; shift 2
    if $PY_CMD "$py_subcmd" "$@" 2>/dev/null; then
      return 0
    fi
    "$ansi_func" "$@"
  }

  ui_banner() {
    [[ "$QUIET" == true ]] && return 0
    if ! $_PY_CMD banner "$1" 2>/dev/null; then _ansi_banner "$1"; fi
  }
  ui_header() {
    [[ "$QUIET" == true ]] && return 0
    if ! $_PY_CMD header "$1" 2>/dev/null; then _ansi_header "$1"; fi
  }
  ui_panel() {
    [[ "$QUIET" == true ]] && return 0
    if ! $_PY_CMD panel "$@" 2>/dev/null; then _ansi_panel "$@"; fi
  }

else  # pure ANSI
  ui_banner() { [[ "$QUIET" == true ]] && return 0; _ansi_banner "$@"; }
  ui_header() { [[ "$QUIET" == true ]] && return 0; _ansi_header "$@"; }
  ui_panel()  { [[ "$QUIET" == true ]] && return 0; _ansi_panel  "$@"; }
fi

fi  # end ansi/richpy mode
