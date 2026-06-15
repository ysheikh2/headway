#!/usr/bin/env bash
# headway installer
#
#   curl -fsSL https://raw.githubusercontent.com/ysheikh2/headway/main/install.sh | bash
#
# To uninstall after installing:
#   headway uninstall

set -euo pipefail

REPO_URL="https://github.com/ysheikh2/headway.git"
INSTALL_DIR="${HEADWAY_INSTALL_DIR:-$HOME/headway}"
SYMLINK="$HOME/.local/bin/headway"

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
    die "missing required tools: ${missing[*]}
    Install them and retry:
      git    → https://git-scm.com
      docker → https://docs.docker.com/get-docker/
      aws    → https://docs.aws.amazon.com/cli/latest/userguide/install-cliv2.html
      python3 → https://www.python.org/downloads/"
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
  grep -qF "headway completion" "$rc_file" 2>/dev/null && {
    success "shell completion already configured in $rc_file"
    return 0
  }

  local eval_line
  eval_line="eval \"\$(\"$INSTALL_DIR/headway\" completion $shell_name)\"  # headway tab completion"
  printf '\n%s\n' "$eval_line" >>"$rc_file"
  success "added tab completion to $rc_file"
}

# ── install ───────────────────────────────────────────────────────────────────

do_install() {
  info "Checking prerequisites..."
  check_prereqs

  info "Installing headway to $INSTALL_DIR..."
  if [[ -d "$INSTALL_DIR/.git" ]]; then
    warn "$INSTALL_DIR already exists — pulling latest changes"
    git -C "$INSTALL_DIR" pull --ff-only
  else
    git clone --depth 1 "$REPO_URL" "$INSTALL_DIR"
  fi
  chmod +x "$INSTALL_DIR/headway"
  success "cloned to $INSTALL_DIR"

  info "Creating symlink at $SYMLINK..."
  mkdir -p "$(dirname "$SYMLINK")"
  ln -sf "$INSTALL_DIR/headway" "$SYMLINK"
  success "symlink created: $SYMLINK → $INSTALL_DIR/headway"

  local rc_file shell_name
  rc_file="$(detect_shell_rc)"
  shell_name="$(detect_shell_name)"

  # Fish uses a different config model: write the completion file directly,
  # PATH management is handled separately via fish_add_path or config.fish.
  if [[ "$shell_name" == "fish" ]]; then
    info "Configuring shell (fish)..."
    local fish_dir="$HOME/.config/fish/completions"
    mkdir -p "$fish_dir"
    bash "$INSTALL_DIR/headway" completion fish >"$fish_dir/headway.fish"
    success "fish completions installed to $fish_dir/headway.fish"
    warn "Add ~/.local/bin to PATH in fish: fish_add_path ~/.local/bin"
  elif [[ -n "$rc_file" ]]; then
    info "Configuring shell ($shell_name)..."

    # Ensure ~/.local/bin is on PATH
    if ! echo "$PATH" | tr ':' '\n' | grep -qF "$(dirname "$SYMLINK")"; then
      add_to_path_in_rc "$rc_file" "$(dirname "$SYMLINK")"
    fi

    add_completion_to_rc "$rc_file" "$shell_name"
  else
    warn "unrecognised shell '$shell_name' — add tab completion manually: eval \"\$(headway completion bash)\""
  fi

  echo
  success "headway installed!"
  echo

  # Guide through init + up if Docker and AWS are available and we're interactive
  if [[ -t 0 ]] && command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1 && command -v aws >/dev/null 2>&1; then
    read -r -p "Complete setup now (AWS auth, model config, start gateway)? (Y/n): " ans
    if [[ -z "$ans" || "$ans" =~ ^[Yy]$ ]]; then
      echo
      info "Running headway init..."
      "$INSTALL_DIR/headway" init
      echo
      info "Starting the gateway (headway up)..."
      "$INSTALL_DIR/headway" up
      echo
      success "All done — headway is running!"
      echo "  Reload your shell to activate tab completion: source $rc_file"
      return
    fi
  fi

  echo "  Next steps:"
  [[ -n "$rc_file" ]] && echo "    1. Reload your shell:  source $rc_file"
  echo "    2. Complete setup:     headway init"
  echo "    3. Start the gateway:  headway up"
  echo
}

# ── main ──────────────────────────────────────────────────────────────────────

do_install "$@"
