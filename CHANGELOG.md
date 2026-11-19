# Changelog

All notable changes to this project are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## 1.0.0

### Added

- Composite action that builds a release at `old-ref` and `new-ref`, boots `old-ref` as a daemon, and runs a real hot code upgrade against it: unpack, synthesize the relup, `check_install_release`, `install_release`, `make_permanent`.
- Detection of relups that load a new module but never start it as a supervised process, via a diff against what the node had loaded before the upgrade.
- `fail-on-relup-warnings` input to treat `systools:make_relup/4` warnings, and the unstarted-module check above, as failures instead of only annotations.
- `boot-timeout-seconds` and `upgrade-timeout-seconds` inputs, so a hang fails fast with a clear reason instead of relying on the calling job's own timeout.
- Verification that the OS process never restarted during the upgrade, catching a disguised full restart that `which_releases/0` alone can't distinguish from a genuine hot swap.
- Job summary output (`$GITHUB_STEP_SUMMARY`) showing old/new refs, versions, and result, including a distinct "succeeded, with warnings" state.
- `working-directory`, `mix-env`, and `build-command` inputs for umbrella apps and non-default release setups.
- Self-test suite (`.github/workflows/ci.yml`) running the action against itself on every push, covering the happy path, both ref-resolution failure modes, both timeout failure modes, and both directions of `fail-on-relup-warnings`.
