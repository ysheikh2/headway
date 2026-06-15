#!/usr/bin/env bash
# headway installer
#
# Quick install (no args needed):
#   curl -fsSL https://raw.githubusercontent.com/ysheikh2/headway/main/install.sh | bash
#
# With options (download first, then run with args):
#   curl -fsSL .../install.sh -o install.sh && bash install.sh --branch my-branch --dir ~/my-headway
#
# Options (all optional — defaults shown):
#   --dir <path>      Install directory  (default: ~/headway)
#   --branch <name>   Git branch to clone (default: repo default branch)
#   --symlink <path>  Symlink location   (default: ~/.local/bin/headway)
#
# To uninstall after installing:
#   headway uninstall

set -euo pipefail

# ── defaults (env vars can also set these, args take precedence) ──────────────
REPO_URL="${HEADWAY_REPO_URL:-https://github.com/ysheikh2/headway.git}"
REPO_BRANCH="${HEADWAY_BRANCH:-}"
INSTALL_DIR="${HEADWAY_INSTALL_DIR:-$HOME/headway}"
SYMLINK="${HEADWAY_SYMLINK:-$HOME/.local/bin/headway}"

# ── helpers ──────────────────────────────────────────────────────────────────

info() { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
success() { printf '\033[1;32m✓\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33mwarn:\033[0m %s\n' "$*" >&2; }
die() {
  printf '\033[1;31merror:\033[0m %s\n' "$*" >&2
  exit 1
}

check_prereqs() {
  local missing=()
  for cmd in git docker aws python3; do
    command -v "$cmd" >/dev/null 2>&1 || missing+=("$cmd")
  done
  if [[ ${#missing[@]} -gt 0 ]]; then
    printf '\033[1;31merror:\033[0m missing required tools: %s\n' "${missing[*]}" >&2
    echo >&2
    for m in "${missing[@]}"; do
      case "$m" in
        git) printf '  %-10s → %s\n' "git" "https://git-scm.com" >&2 ;;
        docker) printf '  %-10s → %s\n' "docker" "https://docs.docker.com/get-docker/" >&2 ;;
        aws) printf '  %-10s → %s\n' "aws" "https://docs.aws.amazon.com/cli/latest/userguide/install-cliv2.html" >&2 ;;
        python3) printf '  %-10s → %s\n' "python3" "https://www.python.org/downloads/" >&2 ;;
      esac
    done
    exit 1
  fi
}

detect_shell_rc() {
  local shell_name
  shell_name="$(basename "${SHELL:-}")"
  case "$shell_name" in
    zsh) echo "$HOME/.zshrc" ;;
    bash) echo "$HOME/.bashrc" ;;
    *) echo "" ;;
  esac
}

detect_shell_name() {
  basename "${SHELL:-bash}"
}

add_to_path_in_rc() {
  local rc_file="$1"
  local dir="$2"
  local marker="# headway PATH"

  [[ -z "$rc_file" ]] && return 0
  grep -qF "$marker" "$rc_file" 2>/dev/null && return 0
  grep -qF "$dir" "$rc_file" 2>/dev/null && return 0

  printf '\nexport PATH="%s:$PATH"  %s\n' "$dir" "$marker" >>"$rc_file"
  success "added $dir to PATH in $rc_file"
}

add_completion_to_rc() {
  local rc_file="$1"
  local shell_name="$2"

  [[ -z "$rc_file" ]] && return 0

  local eval_line
  eval_line="eval \"\$(\"$INSTALL_DIR/headway\" completion $shell_name)\"  # headway tab completion"

  # Use the comment marker to detect any existing headway completion eval line
  if grep -qF "# headway tab completion" "$rc_file" 2>/dev/null; then
    # Already configured for this exact install dir — nothing to do
    if grep -qF "\"$INSTALL_DIR/headway\" completion" "$rc_file" 2>/dev/null; then
      success "shell completion already configured in $rc_file"
      return 0
    fi
    # Stale completion line pointing to a different path — remove and replace.
    # Write filtered content back into the *existing* file (cat >>rc_file, not mv)
    # so the file's inode, owner, and mode are all preserved.
    warn "updating stale completion line in $rc_file"
    local tmpfile
    tmpfile="$(mktemp)"
    grep -v "# headway tab completion" "$rc_file" >"$tmpfile" || true
    cat "$tmpfile" >"$rc_file"
    rm -f "$tmpfile"
  fi

  printf '\n%s\n' "$eval_line" >>"$rc_file"
  success "added tab completion to $rc_file"
}

# ── install ───────────────────────────────────────────────────────────────────

do_install() {
  # ── arg parsing ─────────────────────────────────────────────────────────────
  # Runs only when the script is directly executed (not sourced by unit tests).
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --dir)
        [[ $# -ge 2 && -n "$2" && "$2" != --* ]] || die "--dir requires a non-empty value"
        INSTALL_DIR="$2"
        shift 2
        ;;
      --branch)
        [[ $# -ge 2 && -n "$2" && "$2" != --* ]] || die "--branch requires a non-empty value"
        REPO_BRANCH="$2"
        shift 2
        ;;
      --symlink)
        [[ $# -ge 2 && -n "$2" && "$2" != --* ]] || die "--symlink requires a non-empty value"
        SYMLINK="$2"
        shift 2
        ;;
      --help | -h)
        echo "Usage: bash install.sh [--dir <path>] [--branch <name>] [--symlink <path>]"
        return 0
        ;;
      *)
        echo "Unknown option: $1" >&2
        exit 1
        ;;
    esac
  done

  info "Checking prerequisites..."
  check_prereqs

  # ── clone or update ──────────────────────────────────────────────────────────
  info "Installing headway to $INSTALL_DIR..."

  if [[ -d "$INSTALL_DIR/.git" ]]; then
    local existing_remote
    existing_remote="$(git -C "$INSTALL_DIR" remote get-url origin 2>/dev/null || echo "")"
    if [[ -n "$existing_remote" && "$existing_remote" != "$REPO_URL" ]]; then
      die "$INSTALL_DIR is a git repo for a different remote ($existing_remote). Remove it or set HEADWAY_INSTALL_DIR to a different path."
    fi
    local prev_ref
    prev_ref="$(git -C "$INSTALL_DIR" rev-parse --short HEAD 2>/dev/null || echo "unknown")"
    info "Found existing install ($prev_ref) — pulling latest..."
    if [[ -n "$REPO_BRANCH" ]]; then
      git -C "$INSTALL_DIR" fetch origin "$REPO_BRANCH"
      git -C "$INSTALL_DIR" checkout -B "$REPO_BRANCH" FETCH_HEAD
    else
      local default_branch
      default_branch="$(git -C "$INSTALL_DIR" ls-remote --symref origin HEAD 2>/dev/null |
        awk '/^ref:/{sub("refs/heads/", ""); print $2; exit}')"
      default_branch="${default_branch:-main}"
      git -C "$INSTALL_DIR" fetch origin "$default_branch"
      git -C "$INSTALL_DIR" checkout -B "$default_branch" FETCH_HEAD
    fi
    local new_ref
    new_ref="$(git -C "$INSTALL_DIR" rev-parse --short HEAD 2>/dev/null || echo "unknown")"
    if [[ "$prev_ref" == "$new_ref" ]]; then
      success "already up to date ($new_ref)"
    else
      success "updated $prev_ref → $new_ref"
    fi
  elif [[ -d "$INSTALL_DIR" ]]; then
    die "$INSTALL_DIR exists but is not a git repo. Remove it or set HEADWAY_INSTALL_DIR to a different path."
  else
    local clone_args=(--depth 1)
    [[ -n "$REPO_BRANCH" ]] && clone_args+=(--branch "$REPO_BRANCH")
    git clone "${clone_args[@]}" "$REPO_URL" "$INSTALL_DIR"
    success "cloned to $INSTALL_DIR"
  fi
  chmod +x "$INSTALL_DIR/headway"

  # ── symlink ──────────────────────────────────────────────────────────────────
  info "Creating symlink at $SYMLINK..."
  local bin_dir
  bin_dir="$(dirname "$SYMLINK")"
  mkdir -p "$bin_dir"

  if [[ -L "$SYMLINK" ]]; then
    local current_target
    current_target="$(readlink "$SYMLINK")"
    if [[ "$current_target" == "$INSTALL_DIR/headway" ]]; then
      success "symlink already correct: $SYMLINK → $INSTALL_DIR/headway"
    else
      warn "updating symlink (was → $current_target)"
      ln -sf "$INSTALL_DIR/headway" "$SYMLINK"
      success "symlink updated: $SYMLINK → $INSTALL_DIR/headway"
    fi
  elif [[ -e "$SYMLINK" ]]; then
    warn "$SYMLINK exists and is not a symlink — overwriting"
    [[ -d "$SYMLINK" ]] && rm -rf "$SYMLINK"
    ln -sf "$INSTALL_DIR/headway" "$SYMLINK"
    success "symlink created: $SYMLINK → $INSTALL_DIR/headway"
  else
    ln -sf "$INSTALL_DIR/headway" "$SYMLINK"
    success "symlink created: $SYMLINK → $INSTALL_DIR/headway"
  fi

  # ── shell setup ──────────────────────────────────────────────────────────────
  local rc_file shell_name
  rc_file="$(detect_shell_rc)"
  shell_name="$(detect_shell_name)"

  # Fish uses a different config model: write the completion file directly.
  if [[ "$shell_name" == "fish" ]]; then
    info "Configuring shell (fish)..."
    local fish_dir="$HOME/.config/fish/completions"
    mkdir -p "$fish_dir"
    bash "$INSTALL_DIR/headway" completion fish >"$fish_dir/headway.fish"
    success "fish completions installed to $fish_dir/headway.fish"
    warn "Add $bin_dir to PATH in fish: fish_add_path $bin_dir"
  elif [[ -n "$rc_file" ]]; then
    info "Configuring shell ($shell_name)..."

    if ! echo "$PATH" | tr ':' '\n' | grep -qxF "$bin_dir"; then
      add_to_path_in_rc "$rc_file" "$bin_dir"
    fi

    add_completion_to_rc "$rc_file" "$shell_name"
  else
    warn "unrecognised shell '$shell_name' — add tab completion manually:"
    warn "  eval \"\$(headway completion bash)\""
  fi

  # Warn if bin dir not in current PATH — user needs to reload their shell
  if ! echo "$PATH" | tr ':' '\n' | grep -qxF "$bin_dir"; then
    echo
    warn "$bin_dir is not in your current PATH"
    warn "Open a new terminal (or source your rc file) before using 'headway'"
  fi

  echo
  success "headway installed!"
  echo

  # Guide through init + up if Docker and AWS are available and we're interactive
  if [[ -t 0 ]] && command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1 && command -v aws >/dev/null 2>&1; then
    echo "Setup takes 2–3 minutes and involves two steps:"
    echo "  1. headway init  — configure AWS profile + region, write Kilo/Claude Code"
    echo "                     client presets, discover Bedrock models"
    echo "  2. headway up    — pull Docker images, start the gateway, authorize Copilot"
    echo "                     (GitHub device code — open a browser link when prompted)"
    echo
    read -r -p "Start setup now? (Y/n): " ans
    if [[ -z "$ans" || "$ans" =~ ^[Yy]$ ]]; then
      echo
      info "Step 1/2 — headway init (configure + preflight)"
      echo
      if ! "$INSTALL_DIR/headway" init; then
        echo
        warn "headway init failed — fix the issue above, then run: headway init && headway up"
        return
      fi
      echo
      info "Step 2/2 — headway up (pull images, start gateway)"
      echo
      if ! "$INSTALL_DIR/headway" up; then
        echo
        warn "Gateway did not start cleanly."
        echo "  If Copilot device auth is pending (see link above): run 'headway auth'"
        echo "  Otherwise check Docker logs: docker logs litellm-gateway"
        if [[ -n "$rc_file" ]]; then
          echo
          echo "  Reload your shell first: source $rc_file"
        fi
        return
      fi
      echo
      success "All done — headway is running!"
      echo "  Dashboard:  http://127.0.0.1:4000/dashboard"
      echo "  Stats:      headway stats"
      echo "  Validate:   headway doctor"
      if [[ "$shell_name" == "fish" ]]; then
        echo
        echo "  Restart fish (or open a new terminal) to activate tab completion"
      elif [[ -n "$rc_file" ]]; then
        echo
        echo "  Reload your shell to activate tab completion: source $rc_file"
      fi
      return
    fi
  fi

  echo "  Next steps:"
  [[ -n "$rc_file" ]] && echo "    1. Reload your shell:  source $rc_file"
  echo "    2. Configure:          headway init"
  echo "    3. Start the gateway:  headway up"
  echo "    4. Validate:           headway doctor"
  echo
}

# ── main ──────────────────────────────────────────────────────────────────────
# Guard allows sourcing this file in unit tests to test individual functions.
if [[ "${BASH_SOURCE[0]:-$0}" == "${0}" ]]; then
  do_install "$@"
fi
