#!/usr/bin/env bash
# Example .bashrc addition - add this near the end of your .bashrc
#
# Keep this the ONLY place your shell initializes oh-my-posh: init.sh already runs
# `oh-my-posh init bash --config <owl theme>`, and a second bare `oh-my-posh init bash`
# after it replaces the theme with the default. Put any other PATH additions
# (guarded with a `case ":$PATH:"` check) above this line.
#
# Load developer environment
# Set PREFLIGHT_VERBOSE=1 to see confirmation message
[[ -f "$HOME/.preflight/init.sh" ]] && source "$HOME/.preflight/init.sh"
