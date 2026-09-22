#!/usr/bin/env bash
# Fails when a workflow uses a third-party action or reusable workflow that is
# not pinned to a full commit SHA with its release version as a comment:
#
#   uses: owner/repo[/path]@<40-hex commit sha> # vX.Y.Z
#
# The same rule as LogSquirl's .github/scripts/check-action-pins.sh and the
# shared plugin-security.yml. Local actions (./...) are exempt; docker://
# images must carry a digest.
#
# Usage: scripts/check-action-pins.sh <workflow-file>...
set -euo pipefail

pinned='^[[:space:]]*(-[[:space:]]+)?uses:[[:space:]]+[A-Za-z0-9_.-]+/[A-Za-z0-9_./-]+@[0-9a-f]{40}[[:space:]]+#[[:space:]]+v[0-9]+(\.[0-9]+)*[[:space:]]*$'
exempt='^[[:space:]]*(-[[:space:]]+)?uses:[[:space:]]+(\./|docker://[^[:space:]]+@sha256:[0-9a-f]{64}([[:space:]]|$))'

[ $# -gt 0 ] || { echo "usage: $0 <workflow-file>..." >&2; exit 2; }
status=0
while IFS= read -r hit; do
  file=${hit%%:*}
  rest=${hit#*:}
  line=${rest%%:*}
  text=${rest#*:}
  if ! grep -Eq "$pinned" <<<"$text" && ! grep -Eq "$exempt" <<<"$text"; then
    echo "::error file=$file,line=$line::not pinned to a commit SHA with a '# vX.Y.Z' comment:${text}"
    status=1
  fi
done < <(grep -nE '^[[:space:]]*(-[[:space:]]+)?uses:' "$@" /dev/null || true)

[ "$status" -ne 0 ] || echo "Every action is pinned to a commit SHA."
exit $status
