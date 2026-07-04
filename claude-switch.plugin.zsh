# shellcheck disable=SC2148
# Plugin-manager entry point.
# Sourced automatically by zinit / oh-my-zsh / sheldon / antidote / znap.
#
# Use %x (the file being sourced) rather than $0: $0 only holds the sourced
# path when FUNCTION_ARGZERO is set (the default), so a user with
# `unsetopt function_argzero` would otherwise resolve the wrong directory.
source "${${(%):-%x}:A:h}/cs.zsh"
