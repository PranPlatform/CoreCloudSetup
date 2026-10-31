#!/usr/bin/env bash
# Deletes foundation stacks in reverse dependency order. Lifts termination
# protection first. Must be run as root (the deployer role is denied from
# deleting ${stackPrefix}-* stacks).
#
# Usage: scripts/teardown.sh <config.json> [stack-key ...]
#   stack-key    delete only these stacks (e.g. network-nat); default is all.
#
# You will be asked to type the stack prefix to confirm. AUTO_APPROVE=1 skips it.
set -euo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"

[[ $# -ge 1 ]] || die "Usage: $0 <config.json> [stack-key ...]"

require_tools aws jq
load_config "$1"; shift

SELECTED=("$@")
for key in "${SELECTED[@]+"${SELECTED[@]}"}"; do
  is_known_stack "$key" || die "Unknown stack key '$key'. Valid keys: ${STACK_KEYS[*]}"
done
[[ ${#SELECTED[@]} -gt 0 ]] || SELECTED=("${STACK_KEYS[@]}")

# Reverse deployment order.
TARGETS=()
for (( i=${#STACK_KEYS[@]}-1; i>=0; i-- )); do
  for key in "${SELECTED[@]}"; do
    [[ "$key" == "${STACK_KEYS[$i]}" ]] && TARGETS+=("$(stack_name "$key")")
  done
done

print_identity
warn "This permanently deletes the following stacks and their resources:"
for name in "${TARGETS[@]}"; do warn "  $name"; done
confirm "Type the stack prefix ('$PREFIX') to confirm:" "$PREFIX"

for name in "${TARGETS[@]}"; do delete_stack "$name"; done

log "Done."
