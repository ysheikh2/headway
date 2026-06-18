# headway tab completion (bash/zsh via bashcompinit).
# Source via: eval "$(headway completion)"

_headway_commands=(
  up down update restart reset auth
  init config
  doctor stats test
  cleanup
  uninstall secret-scan completion help
)

_headway_up_flags=(--aws-profile)
_headway_init_flags=(--aws-profile --skip-config)
_headway_config_subcommands=(show regen setup)
_headway_config_setup_targets=(kilo claude all)
_headway_cleanup_targets=(data images kilo claude all)

_headway_bash_completion() {
  local cur prev words cword
  _init_completion 2>/dev/null || {
    COMPREPLY=()
    cur="${COMP_WORDS[COMP_CWORD]}"
    prev="${COMP_WORDS[COMP_CWORD - 1]}"
    words=("${COMP_WORDS[@]}")
    cword=$COMP_CWORD
  }

  local cmd=""
  if [[ ${#words[@]} -ge 2 ]]; then
    cmd="${words[1]}"
  fi

  if [[ $cword -eq 1 ]]; then
    COMPREPLY=($(compgen -W "${_headway_commands[*]}" -- "$cur"))
    return
  fi

  case "$cmd" in
    up)
      case "$prev" in
        --aws-profile) COMPREPLY=() ;;
        *) COMPREPLY=($(compgen -W "${_headway_up_flags[*]}" -- "$cur")) ;;
      esac
      ;;
    init)
      case "$prev" in
        --aws-profile) COMPREPLY=() ;;
        *) COMPREPLY=($(compgen -W "${_headway_init_flags[*]}" -- "$cur")) ;;
      esac
      ;;
    config)
      local sub="${words[2]:-}"
      if [[ $cword -eq 2 ]]; then
        COMPREPLY=($(compgen -W "${_headway_config_subcommands[*]}" -- "$cur"))
      elif [[ "$sub" == "setup" ]]; then
        COMPREPLY=($(compgen -W "${_headway_config_setup_targets[*]}" -- "$cur"))
      fi
      ;;
    cleanup)
      COMPREPLY=($(compgen -W "${_headway_cleanup_targets[*]} --yes" -- "$cur"))
      ;;
    reset | uninstall)
      COMPREPLY=($(compgen -W "--yes" -- "$cur"))
      ;;
    completion)
      COMPREPLY=($(compgen -W "bash zsh fish auto" -- "$cur"))
      ;;
  esac
}

complete -F _headway_bash_completion headway
