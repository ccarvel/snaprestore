#!/usr/bin/env bash
# lib/bootstrap.sh — UI mode detection and optional dependency installation.
# Sourced early in both main scripts. Sets UI_MODE=gum|richpy|ansi.
# May exec-replace the current process into a Docker container.

[[ -n "$_DO_SNAP_BOOTSTRAP" ]] && return 0
export _DO_SNAP_BOOTSTRAP=1

export SNAP_LIB_DIR
SNAP_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

export UI_MODE="ansi"

# ── pre-UI helpers (used before ui.sh is loaded) ──────────────────────────────

_bs_ask() {   # _bs_ask "Question" default_y_or_n → returns 0 (yes) / 1 (no)
  local prompt="$1" default="${2:-Y}"
  local hint
  [[ "${default,,}" == "y" ]] && hint="[Y/n]" || hint="[y/N]"
  local ans
  read -rp "  $prompt $hint: " ans
  ans="${ans:-$default}"
  [[ "${ans,,}" == "y" ]]
}

_bs_info() { printf '  ▸  %s\n'     "$*"; }
_bs_ok()   { printf '  ✓  %s\n'     "$*"; }
_bs_warn() { printf '  ⚠  %s\n'     "$*" >&2; }
_bs_err()  { printf '  ✗  %s\n'     "$*" >&2; }
_bs_sep()  { printf '  %s\n' "$(printf '%0.s─' {1..72})"; }

# ── install helpers ───────────────────────────────────────────────────────────

_bs_install_gum_via_brew() {
  _bs_info "Installing gum via Homebrew…"
  if brew install gum 2>&1 | grep -v '^==>'; then
    _bs_ok "gum installed."
    return 0
  fi
  _bs_warn "brew install gum failed."
  return 1
}

_bs_install_homebrew() {
  _bs_info "Installing Homebrew…"
  /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)" || {
    _bs_warn "Homebrew install failed."
    return 1
  }
  # Activate brew in the current session (Apple Silicon or Intel path)
  [[ -f /opt/homebrew/bin/brew ]] && eval "$(/opt/homebrew/bin/brew shellenv)"
  [[ -f /usr/local/bin/brew    ]] && eval "$(/usr/local/bin/brew shellenv)"
  _bs_ok "Homebrew installed."
}

_bs_install_uv() {
  _bs_info "Installing uv…"
  if curl -LsSf https://astral.sh/uv/install.sh | sh; then
    export PATH="$HOME/.local/bin:$PATH"
    _bs_ok "uv installed."
    return 0
  fi
  _bs_warn "uv install failed."
  return 1
}

# ── Docker re-exec ─────────────────────────────────────────────────────────────
# Replaces the current process. Only returns on failure.

_bs_docker_exec() {
  local script_path="$1"; shift
  local script_args=("$@")
  local script_dir
  script_dir="$(cd "$(dirname "$script_path")" && pwd)"
  local script_name
  script_name="$(basename "$script_path")"

  local image="ghcr.io/ccarvel/snaprestore:latest"

  _bs_info "Pulling $image…"
  if ! docker pull "$image" 2>/dev/null; then
    _bs_warn "Pull failed — building from local Dockerfile…"
    local dockerfile="$script_dir/Dockerfile"
    if [[ ! -f "$dockerfile" ]]; then
      _bs_err "No Dockerfile found at $dockerfile — cannot build."
      return 1
    fi
    if ! docker build -t do-snap-tool "$script_dir"; then
      _bs_err "Docker build failed."
      return 1
    fi
    image="do-snap-tool"
  fi

  _bs_ok "Launching inside container…"
  # shellcheck disable=SC2093
  exec docker run --rm -it \
    -e DIGITALOCEAN_ACCESS_TOKEN \
    -e DO_API_TOKEN \
    -e NO_COLOR \
    -v "$HOME/.config/doctl:/root/.config/doctl:ro" \
    -v "$script_dir:/app" \
    -w /app \
    "$image" \
    bash "$script_name" "${script_args[@]}"
  # exec replaces this process; the line below only runs on exec failure
  _bs_err "exec into Docker failed."
  return 1
}

# ── main bootstrap ────────────────────────────────────────────────────────────
# Call: bootstrap_ui "$0" "${ORIGINAL_ARGS[@]}"
# Walks the decision tree and sets UI_MODE. May exec into Docker.

bootstrap_ui() {
  local script_path="${1:-$0}"; shift 2>/dev/null
  local script_args=("$@")

  # 1. gum already present — best outcome, no prompt needed
  if command -v gum &>/dev/null; then
    UI_MODE="gum"
    export UI_MODE
    return 0
  fi

  echo ""
  _bs_sep
  _bs_info "gum (Charm.sh) not found — it enables a rich terminal UI for this script."
  _bs_sep
  echo ""

  # 2. brew present → offer just gum
  if command -v brew &>/dev/null; then
    if _bs_ask "Install gum via Homebrew?"; then
      if _bs_install_gum_via_brew; then
        UI_MODE="gum"
        export UI_MODE
        return 0
      fi
    fi

  # 3. macOS without brew → offer Homebrew + gum in one shot
  elif [[ "$(uname)" == "Darwin" ]]; then
    if _bs_ask "Install Homebrew + gum?"; then
      if _bs_install_homebrew && _bs_install_gum_via_brew; then
        UI_MODE="gum"
        export UI_MODE
        return 0
      fi
    fi
  fi

  # 4. Docker available → offer container execution
  if command -v docker &>/dev/null; then
    echo ""
    _bs_info "Docker is available — can run with gum pre-installed inside a container."
    if _bs_ask "Run in Docker?"; then
      _bs_docker_exec "$script_path" "${script_args[@]}"
      # Only reaches here if Docker launch failed
      _bs_warn "Docker launch failed — falling back to local UI."
    fi
  fi

  # 5. Python 3 available → try Python rich via uv
  if command -v python3 &>/dev/null; then
    if ! command -v uv &>/dev/null; then
      echo ""
      _bs_info "uv not found — needed for Python rich UI fallback."
      if _bs_ask "Install uv?"; then
        _bs_install_uv || true
      fi
    fi

    if command -v uv &>/dev/null; then
      if uv run --with rich --quiet python3 -c "import rich" 2>/dev/null; then
        UI_MODE="richpy"
        export UI_MODE
        _bs_ok "Using Python rich UI."
        echo ""
        return 0
      fi
    fi
  fi

  # 6. Pure ANSI fallback — always works
  echo ""
  _bs_info "Using built-in ANSI UI (full functionality, no extras needed)."
  echo ""
  UI_MODE="ansi"
  export UI_MODE
}
