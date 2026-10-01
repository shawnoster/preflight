#!/usr/bin/env bash
# ~/.preflight/lib/prompt.sh - Prompting that behaves the same in Bash and zsh
#
# These libraries are sourced from .bashrc and .zshrc. Bash's `read -p "prompt" var`
# prints a prompt, but in zsh `-p` means "read from the coprocess", so the read fails
# silently, leaves the variable empty, and never shows the prompt. Use _pf_ask instead.

# _pf_ask [-s|-k] VAR "prompt"
#   Print the prompt on stderr, read one line from stdin, and store it in VAR.
#   -s  do not echo the input (passwords). The caller prints the newline, as with `read -s`.
#   -k  read a single key instead of a line (Bash `-n 1`, zsh `-k 1`). The caller prints
#       the newline, as with `read -n 1`.
# Returns non-zero when no answer could be read (end of input, or no terminal). A caller
# whose empty answer means "yes" must treat that as a decline:
#   _pf_ask reply "Apply? [Y/n] " || reply=n
_pf_ask() {
  local __silent=0 __key=0
  while [[ "${1:-}" == -* ]]; do
    case "$1" in
      -s) __silent=1 ;;
      -k) __key=1 ;;
    esac
    shift
  done
  local __var="$1" __prompt="$2" __ans=""
  printf '%s' "$__prompt" >&2
  if [[ $__key -eq 1 ]]; then
    if [[ -n "${ZSH_VERSION:-}" ]]; then
      IFS= read -r -k 1 __ans || return 1
    else
      IFS= read -r -n 1 __ans || return 1
    fi
  elif [[ $__silent -eq 1 ]]; then
    IFS= read -r -s __ans || return 1
  else
    IFS= read -r __ans || return 1
  fi
  # eval assigns to the caller's variable by name; the value is never re-expanded.
  eval "$__var=\$__ans"
}
