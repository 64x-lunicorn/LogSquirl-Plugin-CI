#!/usr/bin/env bash
# Runs the "Check plugin.json and .github/plugin-ci.json" step of
# plugin-build.yml against fixture plugins: a valid one must pass with the
# expected outputs, each broken one must fail. Needs yq (the step is read from
# the workflow, so the test runs exactly what the plugins run), jq and git.
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
expect_pass() {
  if ! run "$1"; then
    echo "::error::rejected: $1"; cat "$work/out"; status=1; return
  fi
  if ! grep -qxF "package-files=$2" "$work/output"; then
    echo "::error::$1 gave $(grep '^package-files=' "$work/output"), expected package-files=$2"; status=1; return
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

expect_pass '{"host_ref": "v26.10.0"}' ''
expect_pass '{"host_ref": "v26.10.0", "package_files": []}' ''
expect_pass '{"host_ref": "v26.10.0", "package_files": ["formats/fixture_log.json"]}' 'formats/fixture_log.json'
expect_pass '{"host_ref": "v26.10.0", "package_files": ["formats/fixture_log.json", "formats/other.json"]}' \
  'formats/fixture_log.json formats/other.json'

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

[ "$status" -eq 0 ] && echo "The metadata check accepts and rejects as expected."
exit $status
