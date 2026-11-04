#!/usr/bin/env bash
# The repository settings a plugin's shared workflows rely on but cannot
# declare themselves, the same as LogSquirl's (.github/scripts/repo-settings.sh
# there): read-only GITHUB_TOKEN by default, no pull requests approved by
# workflows, an explicit allowlist of third-party actions, SHA pinning
# required, a protected default branch, protected release tags, and a
# `release` environment that admits only v* tags and holds the signing secrets.
#
# The default branch changes only through pull requests that pass CI / CI
# passed and are up to date, squashed or rebased (linear history). No review
# is required: the maintainer is the only code owner and cannot approve their
# own pull requests. Repository admins may bypass the rules in a pull request.
#
# Usage:
#   scripts/repo-settings.sh <owner/repo> check    # report drift, exit 1 on any
#   scripts/repo-settings.sh <owner/repo> apply    # make the settings match
#   scripts/repo-settings.sh <owner/repo> apply --defer-sha-pinning
#   scripts/repo-settings.sh list-allowed          # ALLOWED_ACTIONS, one per line
#
# --defer-sha-pinning leaves sha_pinning_required as it is (and check does not
# report it): requiring pins while the default branch still has unpinned
# workflows fails every run there. Apply without it once the shared workflows
# are merged.
#
# Secrets are not written here. Put them into the environment with
#   gh secret set <NAME> --env release -R <owner/repo>
# for MACOS_P12_FILE, MACOS_P12_PASSWORD, APPLE_ID, APPLE_TEAM_ID and
# APPLE_PASSWORD; check reports the missing ones.
#
# Needs `gh` authenticated as a repository admin. A third-party action added to
# a shared workflow must be added to ALLOWED_ACTIONS here and applied to every
# plugin; CI of this repository fails until it is listed.
set -euo pipefail

# GitHub-owned actions (actions/*, github/*) are allowed separately. A pattern
# matches subdirectories only when it names them.
ALLOWED_ACTIONS=(
  # The shared workflows themselves.
  '64x-lunicorn/LogSquirl-Plugin-CI/.github/workflows/*@*'
  'apple-actions/import-codesign-certs@*'
  'ilammy/msvc-dev-cmd@*'
  'jurplel/install-qt-action@*'
  # install-qt-action runs its implementation from this subdirectory.
  'jurplel/install-qt-action/action@*'
  'seanmiddleditch/gha-setup-ninja@*'
  'sigstore/cosign-installer@*'
  'softprops/action-gh-release@*'
  'zizmorcore/zizmor-action@*'
)

RELEASE_SECRETS=(MACOS_P12_FILE MACOS_P12_PASSWORD APPLE_ID APPLE_TEAM_ID APPLE_PASSWORD)
TAG_RULESET_NAME="Protect release tags"
BRANCH_RULESET_NAME="Protect main"
# The one check the CI Build reports for the whole run; 15368 is GitHub Actions.
REQUIRED_CHECK="CI / CI passed"
ACTIONS_APP_ID=15368

usage() {
  echo "usage: $0 <owner/repo> check|apply [--defer-sha-pinning] | $0 list-allowed" >&2
  exit 2
}

if [ "${1:-}" = list-allowed ]; then
  printf '%s\n' "${ALLOWED_ACTIONS[@]}"
  exit 0
fi
[ $# -ge 2 ] || usage
REPO=$1
mode=$2
defer_sha_pinning=false
if [ "${3:-}" = "--defer-sha-pinning" ]; then
  defer_sha_pinning=true
elif [ -n "${3:-}" ]; then
  usage
fi
[[ $REPO =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] || usage

drift=0
report() { # name, expected, actual
  if [ "$2" = "$3" ]; then
    echo "ok     $1"
  else
    echo "DRIFT  $1: expected $2, got $3"
    drift=1
  fi
}

allowed_json() {
  printf '%s\n' "${ALLOWED_ACTIONS[@]}" | LC_ALL=C sort | jq -R . | jq -cs .
}

# The ids of the branch rulesets on the default branch, whatever their names:
# apply takes over the first one instead of adding a second.
branch_ruleset_ids() {
  local id
  for id in $(gh api "repos/$REPO/rulesets" --jq '.[] | select(.target == "branch") | .id'); do
    gh api "repos/$REPO/rulesets/$id" --jq 'select(.conditions.ref_name.include | index("~DEFAULT_BRANCH")) | .id'
  done
}

branch_ruleset_body() {
  jq -n --arg name "$BRANCH_RULESET_NAME" --arg check "$REQUIRED_CHECK" --argjson app "$ACTIONS_APP_ID" '{
    name: $name,
    target: "branch",
    enforcement: "active",
    bypass_actors: [{actor_id: 5, actor_type: "RepositoryRole", bypass_mode: "pull_request"}],
    conditions: {ref_name: {include: ["~DEFAULT_BRANCH"], exclude: []}},
    rules: [
      {type: "deletion"},
      {type: "non_fast_forward"},
      {type: "required_linear_history"},
      {type: "pull_request", parameters: {
        required_approving_review_count: 0,
        require_code_owner_review: false,
        dismiss_stale_reviews_on_push: false,
        require_last_push_approval: false,
        required_review_thread_resolution: false,
        allowed_merge_methods: ["squash", "rebase"]
      }},
      {type: "required_status_checks", parameters: {
        strict_required_status_checks_policy: true,
        do_not_enforce_on_create: false,
        required_status_checks: [{context: $check, integration_id: $app}]
      }}
    ]
  }'
}

check() {
  local perms workflow selected ruleset_id env policies secrets
  perms=$(gh api "repos/$REPO/actions/permissions")
  report "actions allowed_actions" selected "$(jq -r .allowed_actions <<<"$perms")"
  if [ "$defer_sha_pinning" = false ]; then
    report "actions sha_pinning_required" true "$(jq -r .sha_pinning_required <<<"$perms")"
  fi

  workflow=$(gh api "repos/$REPO/actions/permissions/workflow")
  report "default_workflow_permissions" read "$(jq -r .default_workflow_permissions <<<"$workflow")"
  report "can_approve_pull_request_reviews" false "$(jq -r .can_approve_pull_request_reviews <<<"$workflow")"

  if [ "$(jq -r .allowed_actions <<<"$perms")" = selected ]; then
    selected=$(gh api "repos/$REPO/actions/permissions/selected-actions")
    report "github_owned_allowed" true "$(jq -r .github_owned_allowed <<<"$selected")"
    report "verified_allowed" false "$(jq -r .verified_allowed <<<"$selected")"
    report "patterns_allowed" "$(allowed_json)" "$(jq -c '.patterns_allowed | sort' <<<"$selected")"
  fi

  ruleset_id=$(gh api "repos/$REPO/rulesets" --jq ".[] | select(.name == \"$TAG_RULESET_NAME\") | .id")
  if [ -z "$ruleset_id" ]; then
    report "tag ruleset" present missing
  else
    local ruleset
    ruleset=$(gh api "repos/$REPO/rulesets/$ruleset_id")
    report "tag ruleset enforcement" active "$(jq -r .enforcement <<<"$ruleset")"
    report "tag ruleset target" '["refs/tags/v*"]' "$(jq -c .conditions.ref_name.include <<<"$ruleset")"
    report "tag ruleset rules" '["creation","deletion","update"]' "$(jq -c '[.rules[].type] | sort' <<<"$ruleset")"
  fi

  local branch_ids
  branch_ids=$(branch_ruleset_ids)
  report "default branch rulesets" 1 "$(grep -c . <<<"$branch_ids" || true)"
  if [ -n "$branch_ids" ]; then
    # What apply writes, in the form GitHub returns it.
    local shape='{name, enforcement, bypass_actors, conditions,
      rules: [.rules[] | {type} + (if .parameters then {parameters: (.parameters | {
        required_approving_review_count, require_code_owner_review, allowed_merge_methods,
        strict_required_status_checks_policy,
        required_status_checks: (.required_status_checks // null | if . then map({context, integration_id}) else null end)
      } | with_entries(select(.value != null)))} else {} end)] | sort_by(.type)}'
    report "default branch ruleset" "$(branch_ruleset_body | jq -cS "$shape")" \
      "$(gh api "repos/$REPO/rulesets/$(head -1 <<<"$branch_ids")" | jq -cS "$shape")"
  fi

  if ! env=$(gh api "repos/$REPO/environments/release" 2>/dev/null); then
    report "release environment" present missing
    return
  fi
  report "release environment custom_branch_policies" true "$(jq -r .deployment_branch_policy.custom_branch_policies <<<"$env")"
  policies=$(gh api "repos/$REPO/environments/release/deployment-branch-policies" \
    --jq '[.branch_policies[] | "\(.type):\(.name)"] | sort')
  report "release environment deployment policies" '["tag:v*"]' "$(jq -c . <<<"$policies")"
  secrets=$(gh api "repos/$REPO/environments/release/secrets" --jq '[.secrets[].name]')
  for s in "${RELEASE_SECRETS[@]}"; do
    report "release environment secret $s" present \
      "$(jq -r --arg s "$s" 'if index($s) then "present" else "missing" end' <<<"$secrets")"
  done
}

apply() {
  # The allowlist can only be written once allowed_actions is "selected"; jobs
  # starting in the seconds between the two calls see GitHub-owned actions only.
  local sha_pinning=true
  if [ "$defer_sha_pinning" = true ]; then
    sha_pinning=$(gh api "repos/$REPO/actions/permissions" --jq .sha_pinning_required)
  fi
  gh api -X PUT "repos/$REPO/actions/permissions" \
    -F enabled=true -f allowed_actions=selected -F sha_pinning_required="$sha_pinning" > /dev/null
  jq -n --argjson patterns "$(allowed_json)" \
    '{github_owned_allowed: true, verified_allowed: false, patterns_allowed: $patterns}' |
    gh api -X PUT "repos/$REPO/actions/permissions/selected-actions" --input - > /dev/null
  gh api -X PUT "repos/$REPO/actions/permissions/workflow" \
    -f default_workflow_permissions=read -F can_approve_pull_request_reviews=false > /dev/null

  # Only repository admins (role id 5) may create release tags; nobody may move
  # or delete one, so a published release keeps pointing at what was attested.
  local body ruleset_id
  body=$(jq -n --arg name "$TAG_RULESET_NAME" '{
    name: $name,
    target: "tag",
    enforcement: "active",
    bypass_actors: [{actor_id: 5, actor_type: "RepositoryRole", bypass_mode: "always"}],
    conditions: {ref_name: {include: ["refs/tags/v*"], exclude: []}},
    rules: [{type: "creation"}, {type: "update"}, {type: "deletion"}]
  }')
  ruleset_id=$(gh api "repos/$REPO/rulesets" --jq ".[] | select(.name == \"$TAG_RULESET_NAME\") | .id")
  if [ -z "$ruleset_id" ]; then
    gh api -X POST "repos/$REPO/rulesets" --input - <<<"$body" > /dev/null
  else
    gh api -X PUT "repos/$REPO/rulesets/$ruleset_id" --input - <<<"$body" > /dev/null
  fi

  ruleset_id=$(branch_ruleset_ids | head -1)
  if [ -z "$ruleset_id" ]; then
    branch_ruleset_body | gh api -X POST "repos/$REPO/rulesets" --input - > /dev/null
  else
    branch_ruleset_body | gh api -X PUT "repos/$REPO/rulesets/$ruleset_id" --input - > /dev/null
  fi

  # The release environment admits v* tags and nothing else.
  jq -n '{deployment_branch_policy: {protected_branches: false, custom_branch_policies: true}}' |
    gh api -X PUT "repos/$REPO/environments/release" --input - > /dev/null
  local policy_ids
  policy_ids=$(gh api "repos/$REPO/environments/release/deployment-branch-policies" \
    --jq '.branch_policies[] | select(.type != "tag" or .name != "v*") | .id')
  for id in $policy_ids; do
    gh api -X DELETE "repos/$REPO/environments/release/deployment-branch-policies/$id" > /dev/null
  done
  if ! gh api "repos/$REPO/environments/release/deployment-branch-policies" \
    --jq '.branch_policies[] | select(.type == "tag" and .name == "v*")' | grep -q .; then
    gh api -X POST "repos/$REPO/environments/release/deployment-branch-policies" \
      -f name='v*' -f type=tag > /dev/null
  fi
}

case "$mode" in
  check) check ;;
  apply) apply; check ;;
  *) usage ;;
esac
exit $drift
