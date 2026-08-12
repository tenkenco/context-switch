# shellcheck disable=SC2148
# Compatibility shim for installs made before the repo was renamed to
# context-switch. Plugin managers resolve <repo-name>.plugin.zsh, so an existing
# `zinit load tenkenco/claude-switch` still finds this file. Keep it.
source "${0:A:h}/cs.zsh"
