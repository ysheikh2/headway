#!/usr/bin/env bash
# Tab completion for the headway CLI.
#
# Bash: add to ~/.bashrc or ~/.bash_profile:
#   eval "$(./headway completion bash)"
#
# Zsh: add to ~/.zshrc:
#   eval "$(./headway completion zsh)"

_headway_commands=(
  init up down auth doctor test update stats config secret-scan reset completion help
)

_headway_init_flags=(--aws-profile --skip-config)
_headway_up_flags=(--aws-profile --regen-config)
_headway_update_flags=(--regen-config)
_headway_config_subcommands=(regen setup show)
_headway_config_regen_flags=(--aws-profile --bedrock-discovery-aws-profile)
_headway_config_setup_targets=(kilo claude all)
_headway_reset_flags=(--yes --purge-data --prune-images --cleanup-kilo --cleanup-claude)

_headway_bash_completion() {
  local cur prev words cword
  _init_completion 2>/dev/null || {
    COMPREPLY=()
    cur="${COMP_WORDS[COMP_CWORD]}"
    prev="${COMP_WORDS[COMP_CWORD - 1]}"
    words=("${COMP_WORDS[@]}")
    cword=$COMP_CWORD
  }

  # Find which top-level command is in effect (words[1] when cword >= 1)
  local cmd=""
  if [[ ${#words[@]} -ge 2 ]]; then
    cmd="${words[1]}"
  fi

  # Complete top-level command
  if [[ $cword -eq 1 ]]; then
    COMPREPLY=($(compgen -W "${_headway_commands[*]}" -- "$cur"))
    return
  fi

  case "$cmd" in
    init)
      case "$prev" in
        --aws-profile) COMPREPLY=() ;;
        *) COMPREPLY=($(compgen -W "${_headway_init_flags[*]}" -- "$cur")) ;;
      esac
      ;;
    up)
      case "$prev" in
        --aws-profile) COMPREPLY=() ;;
        *) COMPREPLY=($(compgen -W "${_headway_up_flags[*]}" -- "$cur")) ;;
      esac
      ;;
    update)
      COMPREPLY=($(compgen -W "${_headway_update_flags[*]}" -- "$cur"))
      ;;
    config)
      local sub="${words[2]:-}"
      if [[ $cword -eq 2 ]]; then
        COMPREPLY=($(compgen -W "${_headway_config_subcommands[*]}" -- "$cur"))
      elif [[ "$sub" == "regen" ]]; then
        case "$prev" in
          --aws-profile | --bedrock-discovery-aws-profile) COMPREPLY=() ;;
          *) COMPREPLY=($(compgen -W "${_headway_config_regen_flags[*]}" -- "$cur")) ;;
        esac
      elif [[ "$sub" == "setup" ]]; then
        COMPREPLY=($(compgen -W "${_headway_config_setup_targets[*]}" -- "$cur"))
      fi
      ;;
    reset)
      COMPREPLY=($(compgen -W "${_headway_reset_flags[*]}" -- "$cur"))
      ;;
    completion)
      COMPREPLY=($(compgen -W "bash zsh fish" -- "$cur"))
      ;;
  esac
}

complete -F _headway_bash_completion headway
complete -F _headway_bash_completion ./headway
