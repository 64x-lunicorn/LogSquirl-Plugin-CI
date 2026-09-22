#!/usr/bin/env bash
# Makes a plugin repository's shared setup match template/, or reports where it
# differs (--check). The shared setup is every file under template/ plus the
# plugin API header, which must be that of the LogSquirl release named by the
# plugin's .github/plugin-ci.json (host_ref).
#
# The workflows under template/ call this repository's shared workflows at
# @PLUGIN_CI_SHA@ # @PLUGIN_CI_VERSION@. Syncing fills in the commit of this
# checkout and its release tag, so plugins always pin a release; Dependabot
# moves the pins from then on, which is why --check ignores which release a
# plugin pins, as long as all its pins name the same one.
#
# Usage:
#   scripts/sync-plugin.sh <plugin-dir>...           copy template/ into each plugin
#   scripts/sync-plugin.sh --check <plugin-dir>...   report drift, exit 1 on any
#
#   --ref <sha> --version <vX.Y.Z>   pin this release instead of HEAD's
set -euo pipefail

root=$(cd "$(dirname "$0")/.." && pwd)
template="$root/template"
host_repo=64x-lunicorn/LogSquirl
header=include/logsquirl_plugin_api.h

mode=sync
ref=""
version=""
plugins=()
while [ $# -gt 0 ]; do
  case "$1" in
    --check) mode=check ;;
    --ref) ref=$2; shift ;;
    --version) version=$2; shift ;;
    -h | --help) sed -n '2,/^set -euo/p' "$0" | sed '$d; s/^# \{0,1\}//'; exit 0 ;;
    -*) echo "unknown option $1" >&2; exit 2 ;;
    *) plugins+=("$1") ;;
  esac
  shift
done
if [ "${#plugins[@]}" -eq 0 ]; then
  echo "usage: $0 [--check] [--ref <sha> --version <vX.Y.Z>] <plugin-dir>..." >&2
  exit 2
fi

if [ "$mode" = sync ]; then
  if [ -z "$ref" ]; then
    ref=$(git -C "$root" rev-parse HEAD)
    version=$(git -C "$root" describe --tags --exact-match HEAD 2>/dev/null) || {
      echo "HEAD of $root is not a release tag; tag it (plugins pin releases) or pass --ref and --version" >&2
      exit 1
    }
  fi
  [[ $ref =~ ^[0-9a-f]{40}$ ]] || { echo "--ref must be a full commit SHA" >&2; exit 2; }
  [[ $version =~ ^v[0-9]+(\.[0-9]+)*$ ]] || { echo "--version must look like v1.2.3" >&2; exit 2; }
fi

# The pin of a shared workflow, as the template writes it and as a plugin has it.
placeholder='@@PLUGIN_CI_SHA@ # @PLUGIN_CI_VERSION@'
pin_re='@[0-9a-f]{40} # v[0-9]+(\.[0-9]+)*'

drift=0
report() { echo "DRIFT  $1: $2"; drift=1; }

host_header() { # host_ref -> header on stdout
  curl -fsSL "https://raw.githubusercontent.com/$host_repo/$1/src/plugins/include/logsquirl_plugin_api.h"
}

for plugin in "${plugins[@]}"; do
  plugin=$(cd "$plugin" && pwd)
  echo "== $plugin"
  if [ ! -f "$plugin/plugin.json" ]; then
    echo "not a plugin (no plugin.json)" >&2
    exit 1
  fi

  while IFS= read -r -d '' src; do
    rel=${src#"$template"/}
    dest="$plugin/$rel"
    if [ "$mode" = sync ]; then
      mkdir -p "$(dirname "$dest")"
      sed "s|$placeholder|@$ref # $version|" "$src" > "$dest"
      echo "synced $rel"
    elif [ ! -f "$dest" ]; then
      report "$rel" "missing"
    elif ! diff -q <(sed -E "s|$pin_re|$placeholder|" "$dest") "$src" > /dev/null; then
      report "$rel" "differs from template/$rel"
      diff -u <(sed -E "s|$pin_re|$placeholder|" "$dest") "$src" | tail -n +3 | sed 's/^/       /' || true
    fi
  done < <(find "$template" -type f -print0 | sort -z)

  # Workflows are shared, all of them: one that is not in template/ is drift.
  for wf in "$plugin"/.github/workflows/*; do
    [ -e "$wf" ] || continue
    rel=${wf#"$plugin"/}
    if [ ! -f "$template/$rel" ]; then
      if [ "$mode" = sync ]; then
        echo "WARN   $rel is not in template/; move what it does into the shared workflows and delete it"
      else
        report "$rel" "not in template/"
      fi
    fi
  done

  if [ "$mode" = check ]; then
    pins=$(grep -hoE "LogSquirl-Plugin-CI/[^@]+$pin_re" "$plugin"/.github/workflows/*.yml 2>/dev/null |
      sed -E 's|^[^@]+||' | sort -u || true)
    if [ "$(printf '%s\n' "$pins" | grep -c .)" -gt 1 ]; then
      report ".github/workflows" "the shared workflows are pinned to different releases: $(tr '\n' ' ' <<<"$pins")"
    fi
  fi

  config="$plugin/.github/plugin-ci.json"
  host_ref=$(jq -r '.host_ref // empty' "$config" 2>/dev/null || true)
  if [ -z "$host_ref" ]; then
    report .github/plugin-ci.json "missing, or without host_ref (see README.md)"
    continue
  fi
  if [ "$mode" = sync ]; then
    host_header "$host_ref" > "$plugin/$header"
    echo "synced $header from LogSquirl $host_ref"
  elif ! diff -q "$plugin/$header" <(host_header "$host_ref") > /dev/null; then
    report "$header" "not the header of LogSquirl $host_ref"
  fi
done

if [ "$mode" = check ]; then
  [ "$drift" -eq 0 ] && echo "No drift."
  exit $drift
fi
