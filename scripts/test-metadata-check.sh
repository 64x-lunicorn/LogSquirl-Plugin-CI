#!/usr/bin/env bash
# Runs the "Check plugin.json and .github/plugin-ci.json" step of
# plugin-build.yml against fixture plugins: a valid one must pass with the
# expected outputs, each broken one must fail. Then the host_ref checks against
# a fixture LogSquirl served by a stub gh: the "Check against LogSquirl" step
# of plugin-build.yml (a pre-release builds) and the "Require a final LogSquirl
# release in host_ref" step of plugin-release.yml (a pre-release is not
# published). Needs yq (the steps are read from the workflows, so the test
# runs exactly what the plugins run), jq and git.
#
# Usage: scripts/test-metadata-check.sh
set -euo pipefail

root=$(cd "$(dirname "$0")/.." && pwd)
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

check="$work/check.sh"
yq -r '.jobs.setup.steps[] | select(.id == "meta") | .run' \
  "$root/.github/workflows/plugin-build.yml" > "$check"
grep -q 'package_files' "$check" || { echo "::error::cannot read the metadata check from plugin-build.yml"; exit 1; }
host_check="$work/host-check.sh"
yq -r '.jobs.setup.steps[] | select(.id == "host") | .run' \
  "$root/.github/workflows/plugin-build.yml" > "$host_check"
grep -q 'releases/tags' "$host_check" || { echo "::error::cannot read the host check from plugin-build.yml"; exit 1; }
release_check="$work/release-check.sh"
yq -r '.jobs.prepare.steps[] | select(.id == "host-ref") | .run' \
  "$root/.github/workflows/plugin-release.yml" > "$release_check"
grep -q 'releases/tags' "$release_check" || { echo "::error::cannot read the host_ref check from plugin-release.yml"; exit 1; }

# A fixture LogSquirl, served by a stub gh that answers the two calls the
# checks make: "gh api repos/<repo>/releases/tags/<tag>" (the release, or 404)
# and "gh api -H ... repos/<repo>/contents/<path>?ref=<tag>" (a file at a tag).
host="$work/host"
header_at() { # tag api_version
  mkdir -p "$host/contents/$1/src/plugins/include" "$host/contents/$1/docker/ubuntu24.04"
  printf '// LogSquirl %s\n#define LOGSQUIRL_PLUGIN_API_VERSION %s\n' "$1" "$2" \
    > "$host/contents/$1/src/plugins/include/logsquirl_plugin_api.h"
  printf 'FROM ubuntu:24.04\nENV QT_VERSION=6.11.3\n' > "$host/contents/$1/docker/ubuntu24.04/Dockerfile"
}
release_of() { # tag prerelease
  mkdir -p "$host/releases"
  printf '{"tag_name": "%s", "draft": false, "prerelease": %s}\n' "$1" "$2" > "$host/releases/$1.json"
}
header_at v26.10.0 1 && release_of v26.10.0 false
header_at v26.11.0-beta1 1 && release_of v26.11.0-beta1 true
header_at v26.11.0-rc1 1 && release_of v26.11.0-rc1 true
header_at v26.09.0 1 && release_of v26.09.0 true   # final form, flagged pre-release
header_at v26.12.0 1                                # a tag without a release
mkdir -p "$work/bin" "$work/tmp"
cat > "$work/bin/gh" <<'GH'
#!/usr/bin/env bash
for endpoint; do :; done
case "$endpoint" in
  repos/*/releases/tags/*) f="$HOST_FIXTURE/releases/${endpoint##*/}.json" ;;
  repos/*/contents/*)
    path=${endpoint#repos/*/contents/}
    f="$HOST_FIXTURE/contents/${path##*\?ref=}/${path%%\?*}" ;;
  *) echo "stub gh: unexpected call: $*" >&2; exit 2 ;;
esac
[ -f "$f" ] || { echo "gh: Not Found (HTTP 404)" >&2; exit 1; }
cat "$f"
GH
chmod +x "$work/bin/gh"

plugin="$work/plugin"
mkdir -p "$plugin/.github" "$plugin/formats" "$plugin/docs" "$plugin/icons"
cd "$plugin"
git init -q
cat > CMakeLists.txt <<'CMAKE'
cmake_minimum_required(VERSION 3.21)
project(logsquirl_fixture VERSION 1.2.3 LANGUAGES CXX)
CMAKE
cat > plugin.json <<'JSON'
{"id": "io.github.logsquirl.fixture", "version": "1.2.3", "library": "logsquirl_fixture",
 "type": "converter", "api_version": 1, "icon": "icons/fixture.svg"}
JSON
echo '<svg/>' > icons/fixture.svg
echo '{}' > formats/fixture_log.json
echo '{}' > formats/other.json
echo '{}' > docs/Other.JSON
echo '{}' > docs/plugin.json
echo '{}' > docs/fixture.svg
echo '{}' > docs/liblogsquirl_fixture.so
echo '{}' > docs/Qt6Foo.dll
: > formats/empty.json
ln -s fixture_log.json formats/link.json
git add -A
echo '{}' > formats/untracked.json
git -c user.name=ci -c user.email=ci@localhost commit -q -m fixture

status=0
# run <plugin-ci.json> -> exit status of the check; its output in $work/out
run() {
  echo "$1" > .github/plugin-ci.json
  : > "$work/output"
  GITHUB_OUTPUT="$work/output" bash -e "$check" > "$work/out" 2>&1
}
# expect_pass <plugin-ci.json> <package-files> [<expected output line>]
expect_pass() {
  if ! run "$1"; then
    echo "::error::rejected: $1"; cat "$work/out"; status=1; return
  fi
  if ! grep -qxF "package-files=$2" "$work/output"; then
    echo "::error::$1 gave $(grep '^package-files=' "$work/output"), expected package-files=$2"; status=1; return
  fi
  if [ -n "${3:-}" ] && ! grep -qxF "$3" "$work/output"; then
    echo "::error::$1 did not give $3:"; cat "$work/output"; status=1; return
  fi
  echo "ok  pass  $1"
}
expect_fail() {
  if run "$1"; then
    echo "::error::accepted: $1"; status=1; return
  fi
  echo "ok  fail  $1"
  grep '::error' "$work/out" | sed 's/^/          /'
}

expect_pass '{"host_ref": "v26.10.0"}' '' 'host-prerelease=false'
expect_pass '{"host_ref": "v26.11.0-beta1"}' '' 'host-prerelease=true'
expect_pass '{"host_ref": "v26.11.0-rc12"}' '' 'host-prerelease=true'
expect_pass '{"host_ref": "v26.10.0", "package_files": []}' ''
expect_pass '{"host_ref": "v26.10.0", "package_files": ["formats/fixture_log.json"]}' 'formats/fixture_log.json'
expect_pass '{"host_ref": "v26.10.0", "package_files": ["formats/fixture_log.json", "formats/other.json"]}' \
  'formats/fixture_log.json formats/other.json'

for ref in '' main 26.10.0 v26.10 v26.10.0.1 v26.11.0-beta v26.11.0-beta0 v26.11.0-beta.1 \
  v26.11.0-BETA1 v26.11.0-alpha1 v26.11.0-beta1-hotfix 'v26.10.0 '; do
  expect_fail "{\"host_ref\": \"$ref\"}"
done
expect_fail '{"host_ref": "v26.10.0", "package_file": ["formats/fixture_log.json"]}'
expect_fail '{"host_ref": "v26.10.0", "package_files": "formats/fixture_log.json"}'
expect_fail '{"host_ref": "v26.10.0", "package_files": [1]}'
expect_fail '{"host_ref": "v26.10.0", "package_files": [""]}'
expect_fail "{\"host_ref\": \"v26.10.0\", \"package_files\": [\"$plugin/formats/fixture_log.json\"]}"
expect_fail '{"host_ref": "v26.10.0", "package_files": ["/etc/passwd"]}'
expect_fail '{"host_ref": "v26.10.0", "package_files": ["../plugin/formats/fixture_log.json"]}'
expect_fail '{"host_ref": "v26.10.0", "package_files": ["formats/../formats/fixture_log.json"]}'
expect_fail '{"host_ref": "v26.10.0", "package_files": ["./formats/fixture_log.json"]}'
expect_fail '{"host_ref": "v26.10.0", "package_files": ["formats//fixture_log.json"]}'
expect_fail '{"host_ref": "v26.10.0", "package_files": ["formats/fixture_log.json/"]}'
expect_fail '{"host_ref": "v26.10.0", "package_files": ["formats\\fixture_log.json"]}'
expect_fail '{"host_ref": "v26.10.0", "package_files": ["formats/*.json"]}'
expect_fail '{"host_ref": "v26.10.0", "package_files": ["formats/fixture log.json"]}'
expect_fail '{"host_ref": "v26.10.0", "package_files": ["formats"]}'
expect_fail '{"host_ref": "v26.10.0", "package_files": ["formats/untracked.json"]}'
expect_fail '{"host_ref": "v26.10.0", "package_files": ["formats/missing.json"]}'
expect_fail '{"host_ref": "v26.10.0", "package_files": ["formats/link.json"]}'
expect_fail '{"host_ref": "v26.10.0", "package_files": ["formats/empty.json"]}'
expect_fail '{"host_ref": "v26.10.0", "package_files": ["docs/plugin.json"]}'
expect_fail '{"host_ref": "v26.10.0", "package_files": ["docs/fixture.svg"]}'
expect_fail '{"host_ref": "v26.10.0", "package_files": ["docs/liblogsquirl_fixture.so"]}'
expect_fail '{"host_ref": "v26.10.0", "package_files": ["docs/Qt6Foo.dll"]}'
expect_fail '{"host_ref": "v26.10.0", "package_files": ["formats/other.json", "docs/Other.JSON"]}'
expect_fail '{"host_ref": "v26.10.0", "package_files": ["formats/other.json", "formats/other.json"]}'

# run_step <script> <host_ref> -> exit status of the step; output in $work/out.
# The plugin vendors the header of the host_ref, so only host_ref decides.
run_step() {
  local script=$1 ref=$2 prerelease=false
  [[ $ref != *-* ]] || prerelease=true
  echo "{\"host_ref\": \"$ref\"}" > .github/plugin-ci.json
  mkdir -p include
  cp "$host/contents/$ref/src/plugins/include/logsquirl_plugin_api.h" include/ 2>/dev/null ||
    echo '// none' > include/logsquirl_plugin_api.h
  : > "$work/output"
  PATH="$work/bin:$PATH" HOST_FIXTURE="$host" HOST_REPO=64x-lunicorn/LogSquirl \
    HOST_REF="$ref" HOST_PRERELEASE="$prerelease" RUNNER_TEMP="$work/tmp" \
    GITHUB_OUTPUT="$work/output" bash -e "$script" > "$work/out" 2>&1
}
# expect_step <pass|fail> <name> <script> <host_ref> [<text the output must hold>]
expect_step() {
  local want=$1 name=$2 script=$3 ref=$4 text=${5:-} got=pass
  run_step "$script" "$ref" || got=fail
  if [ "$got" != "$want" ]; then
    echo "::error::$name: host_ref $ref should $want, did $got:"; cat "$work/out"; status=1; return
  fi
  if [ -n "$text" ] && ! grep -qF -- "$text" "$work/out" "$work/output"; then
    echo "::error::$name: host_ref $ref did not say '$text':"; cat "$work/out"; status=1; return
  fi
  echo "ok  $want  $name: $ref"
  grep -E '::(error|warning)' "$work/out" | sed 's/^/          /' || true
}

build="build Setup"
expect_step pass "$build" "$host_check" v26.10.0 'qt-version=6.11.3'
expect_step pass "$build" "$host_check" v26.11.0-beta1 '::warning'
expect_step pass "$build" "$host_check" v26.11.0-beta1 'qt-version=6.11.3'
expect_step pass "$build" "$host_check" v26.09.0 '::warning'
expect_step fail "$build" "$host_check" v26.12.0 'not a published release'
expect_step fail "$build" "$host_check" v26.11.0-beta2 'not a published release'
if run_step "$host_check" v26.10.0 && grep -q '::warning' "$work/out"; then
  echo "::error::$build warns about the final release v26.10.0"; status=1
fi

release="CI Release"
expect_step pass "$release" "$release_check" v26.10.0
expect_step fail "$release" "$release_check" v26.11.0-beta1 'switch host_ref to the final LogSquirl release'
expect_step fail "$release" "$release_check" v26.11.0-rc1 'switch host_ref to the final LogSquirl release'
expect_step fail "$release" "$release_check" v26.11.0-beta.1 'switch host_ref to the final LogSquirl release'
expect_step fail "$release" "$release_check" v26.09.0 'switch host_ref to the final LogSquirl release'
expect_step fail "$release" "$release_check" v26.12.0 'not a published release'
expect_step fail "$release" "$release_check" main 'not a LogSquirl release tag'

[ "$status" -eq 0 ] && echo "The metadata and host_ref checks accept and reject as expected."
exit $status
