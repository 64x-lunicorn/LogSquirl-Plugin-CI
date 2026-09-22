# LogSquirl-Plugin-CI

The shared CI/CD of every LogSquirl plugin. Each plugin repository carries the
same small caller workflows and the same shared files; everything they run
lives here, pinned by commit SHA, so a fix lands once and reaches every plugin
through Dependabot.

| Plugin | Repository |
|---|---|
| Custom Footer | [LogSquirl-CustomFooter](https://github.com/64x-lunicorn/LogSquirl-CustomFooter) |
| Android Logcat | [LogSquirl-Logcat](https://github.com/64x-lunicorn/LogSquirl-Logcat) |
| Serial Monitor | [LogSquirl-Serial](https://github.com/64x-lunicorn/LogSquirl-Serial) |
| tcpdump / pcap Viewer | [LogSquirl-tcpdump](https://github.com/64x-lunicorn/LogSquirl-tcpdump) |

## What a plugin runs

| Caller in the plugin | Shared workflow | What it does |
|---|---|---|
| `ci-build.yml` | [`plugin-build.yml`](.github/workflows/plugin-build.yml) | Checks `plugin.json` against `CMakeLists.txt` and the LogSquirl release it targets, checks formatting, builds and tests on Linux x64, macOS arm64 and Windows x64, checks the exported entry points, packages each platform unsigned. One required check: **CI / CI passed**. |
| `ci-release.yml` | [`plugin-release.yml`](.github/workflows/plugin-release.yml) | On a `v*` tag: publishes the CI Build artifacts of the tagged commit (no rebuild), signs and notarizes macOS in the `release` environment, adds a checksum file, provenance attestations and a Sigstore signature, and hands over the `releases.json` entry with real SHA-256s. |
| `workflow-security.yml` | [`plugin-security.yml`](.github/workflows/plugin-security.yml) | zizmor (code scanning, fails on high severity) and the SHA pin check. |

The model is LogSquirl's own CI: SHA-pinned actions, `permissions: {}` by
default, `persist-credentials: false`, timeouts on every job, signing secrets
only in a `release` environment that admits `v*` tags, and releases that ship
the build that passed CI.

## What is shared, what is per plugin

Shared, identical in every plugin ([`template/`](template)), kept so by
`scripts/sync-plugin.sh`:

```
.clang-format                         LogSquirl's
.gitignore
.github/CODEOWNERS
.github/dependabot.yml
.github/requirements/clang-format.*   hash-locked clang-format, LogSquirl's version
.github/workflows/ci-build.yml
.github/workflows/ci-release.yml
.github/workflows/workflow-security.yml
include/logsquirl_plugin_api.h        from the LogSquirl release in host_ref
```

Per plugin:

- `plugin.json`: `id`, `version`, `library`, `type`, `api_version`, `icon`.
  The CMake target must be named after `library`, and `project(VERSION)` must
  equal `version` (without a pre-release suffix).
- `.github/plugin-ci.json`:

  ```json
  {
    "host_ref": "v26.07.0",
    "qt_modules": ["qtserialport"],
    "bundle_qt_frameworks": ["QtSerialPort"]
  }
  ```

  `host_ref` is the LogSquirl release the plugin is built against: CI takes
  that release's Qt version and requires its plugin API header byte for byte.
  `qt_modules` are extra aqt modules to install, `bundle_qt_frameworks` the
  Qt frameworks the macOS package carries because the host app does not ship
  them. Both may be omitted.
- `CHANGELOG.md` with one `## [X.Y.Z]` section per release: the release notes.
- `releases.json`: the plugin's catalog entry list.

## Releasing a plugin

1. On `main`: set `version` in `plugin.json` and `project(VERSION)` in
   `CMakeLists.txt`, add the `## [X.Y.Z]` section to `CHANGELOG.md`, merge.
2. Push the tag `vX.Y.Z` (or `vX.Y.Z-beta.N`) on that commit. CI Release waits
   for CI Build of the commit if it is still running.
3. Commit the `releases.json` from the run's summary (artifact
   `releases-json`) to `main`, so the catalog offers the version.

## Changing the shared setup

1. Change the shared workflows or `template/` here; CI checks actionlint,
   shellcheck, zizmor, pins, the action allowlist and the sync round trip.
2. A new third-party action goes into `ALLOWED_ACTIONS` in
   `scripts/repo-settings.sh`, applied to every plugin before the release.
3. Tag a release `vX.Y.Z`. Dependabot in each plugin proposes the new pins,
   all three in one pull request.
4. When `template/` changed, run `scripts/sync-plugin.sh <plugin-dir>...` on
   a checkout of this release and open the pull requests. Plugin Drift reports
   every plugin whose shared files differ from `template/`.

## Setting up a plugin repository

```sh
scripts/sync-plugin.sh ../LogSquirl-Foo              # shared files and header
scripts/repo-settings.sh 64x-lunicorn/LogSquirl-Foo apply
gh secret set MACOS_P12_FILE --env release -R 64x-lunicorn/LogSquirl-Foo
# ... MACOS_P12_PASSWORD, APPLE_ID, APPLE_TEAM_ID, APPLE_PASSWORD
scripts/repo-settings.sh 64x-lunicorn/LogSquirl-Foo check
```

Add the plugin to the matrix in `plugin-drift.yml` and to the table above.
