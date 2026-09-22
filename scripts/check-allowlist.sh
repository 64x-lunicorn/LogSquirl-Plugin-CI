#!/usr/bin/env bash
# Fails when a workflow uses a third-party action that repo-settings.sh does
# not allow: a plugin repository runs allowlisted actions only, so such a
# workflow would fail in every plugin with "action is not allowed". Actions
# that an action calls internally are not visible here; list them in
# repo-settings.sh by hand (like jurplel/install-qt-action/action).
#
# Usage: scripts/check-allowlist.sh <workflow-file>...
set -euo pipefail

root=$(cd "$(dirname "$0")/.." && pwd)
[ $# -gt 0 ] || { echo "usage: $0 <workflow-file>..." >&2; exit 2; }
patterns=()
while IFS= read -r p; do patterns+=("$p"); done < <("$root/scripts/repo-settings.sh" list-allowed)

status=0
while IFS= read -r name; do
  case "$name" in
    actions/* | github/*) continue ;; # GitHub-owned, allowed separately
  esac
  allowed=false
  for p in "${patterns[@]}"; do
    # shellcheck disable=SC2053 # the pattern is a glob on purpose
    if [[ $name == ${p%@*} ]]; then allowed=true; break; fi
  done
  if [ "$allowed" = true ]; then
    echo "ok     $name"
  else
    echo "::error::$name is not in ALLOWED_ACTIONS (scripts/repo-settings.sh)"
    status=1
  fi
done < <(grep -hoE '^[[:space:]]*(-[[:space:]]+)?uses:[[:space:]]+[A-Za-z0-9_.-]+/[^@[:space:]]+' "$@" |
  sed -E 's/.*uses:[[:space:]]+//' | sort -u)
exit $status
