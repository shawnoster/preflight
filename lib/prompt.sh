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
# Returns non-zero when no answer could be read (end of input, or no terminal), and then
# sets VAR to the empty string rather than leaving whatever it held before: a stale "y"
# must never approve the next confirmation. A caller whose empty answer means "yes" must
# still treat the failure as a decline:
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
  local __var="$1" __prompt="$2" __ans="" __rc=0
  printf '%s' "$__prompt" >&2
  if [[ $__key -eq 1 ]]; then
    if [[ -n "${ZSH_VERSION:-}" ]]; then
      IFS= read -r -k 1 __ans || __rc=1
    else
      IFS= read -r -n 1 __ans || __rc=1
    fi
  elif [[ $__silent -eq 1 ]]; then
    IFS= read -r -s __ans || __rc=1
  else
    IFS= read -r __ans || __rc=1
  fi
  # A failed read can still have filled __ans with a final line that had no newline.
  # That is not an answer a person gave, so discard it.
  [[ $__rc -eq 0 ]] || __ans=""
  # eval assigns to the caller's variable by name; the value is never re-expanded.
  eval "$__var=\$__ans"
  return $__rc
}
