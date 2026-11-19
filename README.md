# relup-guard-elixir

CI action that verifies Elixir hot code upgrades actually work, by building old and new Mix releases and running a real relup before you merge.

## Why

A release can build cleanly and still fail to hot-upgrade: a missing appup, a `code_change/3` that doesn't match the new state shape, a dependency bump with no upgrade instructions.
Most CI pipelines only check that a release *builds*.
They never check that an upgrade into it actually *applies* against a live node.
`relup-guard-elixir` closes that gap: it builds the release at your PR's base ref and at its head in the same working directory (so Mix appup tooling can see both), boots the old release, and drives the same sequence a real deploy does - unpack, synthesize the relup, `check_install_release`, `install_release`, `make_permanent` - against it.
If any step fails, the PR fails, before the broken upgrade ever reaches production.

## Prerequisites

Your project needs the following already in place; `relup-guard-elixir` does not set any of it up for you.

- A `mix release` whose `:steps` include `:tar` plus a step that does two things: generate `.appup` files, and copy the assembled `.rel` file into a flat `releases/<name>-<vsn>.rel` (not the nested `releases/<vsn>/<name>.rel` a plain `mix release` already produces on its own). `release_handler:unpack_release/1` specifically needs that flat copy to exist - without it, unpacking the new release fails outright, regardless of whether the `.appup` files themselves are fine. [Jellyfish](https://hex.pm/packages/jellyfish)'s `&Jellyfish.generate/1` does both and is what this project's own fixture and self-test use - but Jellyfish itself isn't required, as long as whatever tool you use does the same flat-copy. It does not produce a `relup`; `relup-guard-elixir` synthesizes that itself at upgrade time, the same way a real deploy does.
- The `:sasl` application included in the release, since `release_handler` lives there.
- The calling workflow must check out the repository with `fetch-depth: 0`, so both `old-ref` and `new-ref` are reachable as git history.
- The calling workflow must set up the Erlang/Elixir toolchain itself (e.g. with `erlef/setup-beam`), matching whatever `.tool-versions` or version pins your project uses.
- A Linux or macOS runner (e.g. `ubuntu-24.04`).
  Mix releases only support daemon/pid/rpc boot-script commands on Unix; Windows releases use a separate, admin-only service mode with none of them, so `relup-guard-elixir` fails fast with an explanation rather than running on `windows-*`.

`relup-guard-elixir` checks out `old-ref` and then `new-ref` in place, in the job's own working directory, so it leaves the checkout on `new-ref` when it finishes.
Run it as its own job, or as the last step in a job, rather than before other steps that assume the original checkout is untouched.

## Usage

```yaml
name: Verify hot upgrade

on:
  pull_request:
    branches: [main]

jobs:
  relup-guard-elixir:
    runs-on: ubuntu-24.04
    steps:
      - uses: actions/checkout@v7
        with:
          fetch-depth: 0

      - uses: erlef/setup-beam@v1
        with:
          version-file: .tool-versions
          version-type: strict

      - uses: deployex/relup-guard-elixir@v1
        with:
          old-ref: ${{ github.event.pull_request.base.sha }}
          release-name: my_app
```

Tags above are pinned to a major version, not a commit SHA: a tag can move to point at different code later, which a SHA cannot.
This repository's own `.github/workflows/ci.yml` makes the same choice, paired with a `.github/dependabot.yml` for the `github-actions` ecosystem that opens a PR whenever a pinned major version has a newer release.
If you'd rather not depend on that - a tag you don't control being trustworthy for as long as you use it - pin to a full commit SHA instead and keep the tag as a trailing comment, e.g. `uses: actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1 # v7.0.1`.

### Booting a release that needs environment variables

If your release reads `System.get_env/1` in `config/runtime.exs` (database URL, secret key base, etc.), set those as `env` on the step that calls `relup-guard-elixir`, not as an `with:` input.
Composite action steps run inside the same job as the step that calls them, so any `env:` set there is inherited by every step inside `relup-guard-elixir`, including the one that actually boots the release:

```yaml
- uses: deployex/relup-guard-elixir@v1
  env:
    DATABASE_URL: ecto://postgres:postgres@localhost/my_app_test
    SECRET_KEY_BASE: ${{ secrets.SECRET_KEY_BASE }}
  with:
    old-ref: ${{ github.event.pull_request.base.sha }}
    release-name: my_app
```

A few things this doesn't cover:

- If `runtime.exs` checks out a real dependency, such as a database, that dependency has to actually be reachable in the job (e.g. a `services:` container), the same as it would for any other test job.
- `relup-guard-elixir` sets `RELEASE_COOKIE`, `RELEASE_NODE`, and `RELEASE_DISTRIBUTION` itself, to boot the old release under a node name and cookie unique to that run - not just on a single runner, but across two concurrent jobs sharing the same self-hosted runner, where a fixed node name would otherwise let one job's RPCs land on the other job's node. If your own `runtime.exs` reads any of those three specifically, treat them as reserved - whatever you set will be overridden.
- It also appends `-kernel inet_dist_use_interface {127,0,0,1}` to the extracted release's `vm.args`/`remote.vm.args`, restricting its Erlang distribution listener to loopback. This matters most on a self-hosted runner reachable on a wider network: without it, Erlang distribution binds to every interface by default regardless of the node name's own hostname, leaving a short-lived window where the test node is reachable network-wide, guarded only by a cookie that (unlike a real production one) is just a timestamp and pid.
- If the upgrade itself raises - inside `unpack_release`/`make_relup`/`install_release`, or inside anything an `apply` instruction invokes as part of applying it, such as a newly-started child's `start_link` - `relup-guard-elixir` prints the raw Erlang/Elixir crash term to the job log so the actual cause is visible, and that term can contain whatever value was in scope at the point of the crash. That's a problem if the value is a secret your own code fetched at runtime (e.g. from a secrets manager, via a config provider pattern) rather than one that came in through this step's own `env:`. GitHub automatically masks values it already knows are secrets - the ones passed through its own `secrets:` context - but it has no way to know about a value your application fetched on its own, so that one can't be auto-masked by default. If that's a real risk for your release, mask it yourself in the calling workflow: GitHub's `::add-mask::` command (`echo "::add-mask::$THE_VALUE"`) matches by value wherever it later appears in the log, including from inside a nested crash dump this step prints. This specifically does not apply to the old release simply failing to boot in the first place - that path only ever reports a generic timeout, with no crash detail to leak.

### Booting a release that needs a database

If the release starts an `Ecto.Repo` (or anything else that connects out on boot), the old release simply won't come up without that dependency reachable, and `relup-guard-elixir` will time out with a generic "did not boot" error rather than the real cause.
This is the same problem as running `mix test` in CI, and it has the same fix: add the dependency as a `services:` container on the job, and point the release at it with `env:`.

```yaml
jobs:
  relup-guard-elixir:
    runs-on: ubuntu-24.04
    services:
      postgres:
        image: postgres:16
        env:
          POSTGRES_PASSWORD: postgres
        ports: ["5432:5432"]
        options: >-
          --health-cmd pg_isready
          --health-interval 10s
          --health-timeout 5s
          --health-retries 5
    steps:
      - uses: actions/checkout@v7
        with:
          fetch-depth: 0

      - uses: erlef/setup-beam@v1
        with:
          version-file: .tool-versions
          version-type: strict

      - uses: deployex/relup-guard-elixir@v1
        env:
          DATABASE_URL: ecto://postgres:postgres@localhost:5432/my_app
        with:
          old-ref: ${{ github.event.pull_request.base.sha }}
          release-name: my_app
```

If the schema needs to exist before the release will boot (rather than being created by the release itself on startup), run migrations against that database as a step before `relup-guard-elixir`, the same way you would before a normal integration test job.
`relup-guard-elixir` has no opinion on this either way - it boots whatever `bin/<name> daemon` boots, exactly as a real deploy would.

### Inputs

| Input | Required | Default | Description |
|---|---|---|---|
| `old-ref` | yes | - | Git ref/SHA to build as the currently-deployed release. |
| `new-ref` | no | `HEAD` | Git ref/SHA to build as the release being tested. |
| `release-name` | yes | - | The release name from `mix.exs`, under `releases[...]`. |
| `mix-env` | no | `prod` | `MIX_ENV` used to build both releases. |
| `working-directory` | no | `.` | Directory containing the `mix.exs` that defines the release, relative to the repository root. Use this when the release isn't built from the repository root (e.g. one app of an umbrella). |
| `build-command` | no | `mix deps.get && mix release` | Command run to produce the release tarball, once per ref, in `working-directory`. |
| `boot-timeout-seconds` | no | `30` | How long to wait for the old release to boot before failing. Must be a non-negative integer - anything else fails fast with a clear error instead of being silently misread. |
| `upgrade-timeout-seconds` | no | `60` | How long to wait for the unpack/make_relup/install/make_permanent sequence to finish before treating it as hung and failing fast, rather than relying on the calling job's own timeout. Must be a non-negative integer - anything else fails fast with a clear error instead of being silently misread. |
| `fail-on-relup-warnings` | no | `false` | Treat `systools:make_relup/4` warnings, and relup-guard-elixir's own "module loaded but possibly never started" check, as failures instead of only annotating them with `::warning::`. |

### Outputs

| Output | Description |
|---|---|
| `old-version` | The version string built from `old-ref`. |
| `new-version` | The version string built from `new-ref`. |
| `had-warnings` | `"true"` if the upgrade succeeded but raised a relup warning (see step 6 below), `"false"` otherwise. |

## How it works

1. **Resolve old-ref and new-ref to commit SHAs first, before anything checks either one out.**
   This has to happen against the calling workflow's own pristine checkout: once old-ref is checked out in the next step, the literal string `"HEAD"` - new-ref's own default - no longer means "the commit the job originally checked out", it means "whatever we're currently sitting on", which by then is old-ref itself.
2. **Build old-ref, then new-ref, in the same working directory.**
   Mix appup tooling (Jellyfish included) finds the "previous version" to diff against by looking inside the same `_build/<env>/rel/<name>/releases/` tree a prior build already populated, not from git history directly - so the two builds have to be sequential in place, the same way `git checkout <old> && mix release && git checkout <new> && mix release` would work by hand.
3. **Fail fast if the versions are identical.**
   A relup needs two distinct versions to exist at all.
4. **Boot the old release as a daemon**, using an isolated node name and cookie so it cannot collide with anything else running on the runner, and `-kernel inet_dist_use_interface {127,0,0,1}` so its Erlang distribution port is actually restricted to loopback rather than the all-interfaces default Erlang distribution uses regardless of what hostname the node name itself says.
5. **Unpack the new release into it** via `release_handler:unpack_release/1`, which places the new `.rel` and `lib/<app>-<new-version>/ebin` alongside the old ones on the already-running node.
   If the tarball is missing the flat `.rel` file described under Prerequisites, this fails with a specific explanation naming that exact missing path, rather than the raw `{:error, {:enoent, Path}}` tuple `unpack_release/1` itself returns.
6. **Synthesize the relup** via `systools:make_relup/4`, now that both versions' `.rel` files and the new version's `.appup` files coexist on that node - this is the step most naive "does it build" checks skip entirely.
   Any warnings `systools` returns (not just its errors) are surfaced as a `::warning::` annotation rather than silently discarded - a relup that "succeeds" with warnings often means `systools` fell back to a cruder instruction than intended, such as reloading everything for a dependency that bumped version with no `.appup` of its own.
   Set `fail-on-relup-warnings: true` to turn that `::warning::` into a build failure instead, the same "warnings as errors" choice many build and lint tools offer.
   Separately, relup-guard-elixir also checks the relup for modules that get loaded but never started: if the new version introduces a module this node didn't have loaded before, and the upgrade script has no `apply` instruction anywhere, that's surfaced the same way (and controlled by the same `fail-on-relup-warnings` flag).
   This is a real gap in auto-generated appups, not a hypothetical one: a module *loading* successfully says nothing about whether it was wired into a supervisor, because `load`/`load_object_code` only load code - starting a new supervised child needs its own explicit `apply` instruction (e.g. `supervisor:start_child`), per the OTP appup cookbook's documented pattern for this exact case.
   A module flagged this way is not necessarily a bug - plenty of new modules aren't processes that need starting - so this stays a warning by default rather than a failure.
7. **Apply it for real, bounded by `upgrade-timeout-seconds`**: `release_handler:check_install_release/1`, `release_handler:install_release/2`, then `release_handler:make_permanent/1`.
   A hang here (a process not acknowledging `code_change`, a deadlocked supervisor) is killed and reported as a timeout rather than silently eating the calling job's own multi-hour default timeout.
8. **Confirm the new version is actually the one left running**, via `release_handler:which_releases/0`, rather than trusting that the install calls alone imply success.
9. **Confirm the OS process never restarted**, by comparing the node's OS pid before and after.
   The entire point of a hot upgrade is that the running process survives it; `which_releases/0` alone can't tell a genuine in-place code swap from a disguised full restart (a stray `restart_new_emulator` instruction, or an init system quietly restarting a crashed node) that happens to land on the right version anyway.
10. **Stop the node** and report pass/fail.
11. **Write old-version, new-version, and the result to the job's Summary tab**, via `$GITHUB_STEP_SUMMARY` - the same convention `actions/cache` and other popular actions use so the outcome is visible at a glance without opening step logs, even when an earlier step failed first. `$GITHUB_STEP_SUMMARY` is scoped to the step that writes it, though: a later step in the calling workflow can't read this content back through that same env var, even within the same job - use the `had-warnings` output instead for that.
    A success with `fail-on-relup-warnings` left false but a warning raised anyway shows as its own distinct "⚠️ succeeded, with warnings" result, not an indistinguishable plain "✅" - otherwise the summary's whole point (visible at a glance) would fail silently for exactly the runs it matters most for.

## What this does not do (yet)

- **Erlang/rebar3 releases.**
  Deliberately out of scope, not just "not yet implemented": where a tarball lands, what a boot script's subcommands are called, and how appup/relup generation works all differ enough from Mix that supporting both well would mean branching most of this logic by build tool, for audiences that barely overlap. [`ferd/dandelion`](https://github.com/ferd/dandelion) (see References) already does this for rebar3/relx, proven and working - a rebar3 equivalent of this action would sensibly be modeled directly on its `relup-ci.yml`, as its own small, separate project, rather than grafted onto this one.
- **Version-bump convention enforcement.**
  v1 only checks that the upgrade executes correctly, with no opinion on whether the version bump itself was the "right size" for the change (a Smoothver-style `RESTART.RELUP.RELOAD` scheme, for example).
  That can be layered on top later as an optional check.
- **A pristine checkout afterward.**
  Because old-ref and new-ref are built sequentially in place, the repository ends up checked out at `new-ref`, with build artifacts from both versions in `_build`.
  See the note under Prerequisites about where to place this in your job.
- **Testing the downgrade path.**
  A relup file actually contains instructions both ways - `release_handler:install_release/2` can walk a running node forward *or* back - which looks like it should make "also test the rollback" a cheap addition, the same way database-migration tooling tests `down` as well as `up`.
  It isn't, for the specific pair of versions this action builds: `old-ref`'s release only exists on the test node because it was booted directly from its own boot script, never unpacked through `release_handler`, so `release_handler:which_releases/0` reports it with an empty app list, and any script instruction that needs that app list (`load_object_code`, in practice every non-trivial relup) fails with `{case_clause, false}` deep in `release_handler_1:eval/2`.
  Rolling back a release that *was* installed through `release_handler` (i.e. any version after the first one a node ever ran) does not hit this, because `unpack_release` is what populates that app list in the first place; testing that path for real would need a third, already-"managed" version to roll back to, which is a bigger addition than the two-version model this action builds on.
  This is called out here rather than offered as a flag because no flag would make it work for the versions this action actually has on hand - if you want confidence in your own rollback path, test it against two versions you have already deployed through `release_handler` at least once, not against a freshly booted node.

## Tested against

`fixtures/demo_app` is a minimal Mix release: one GenServer (`RelupDemo.Worker`) with a `code_change/3` that migrates its state shape, plus a second supervisor child (`RelupDemo.Worker2`) with no corresponding appup `apply` instruction, specifically to exercise the "unstarted module" check.

`.github/workflows/ci.yml` runs `relup-guard-elixir` against itself on every push:

- The main self-test job, and two more exercising `new-ref`'s documented default and a deterministic `boot-timeout-seconds: "0"` failure, build from a dedicated `fixtures/baseline` branch (an earlier state of `fixtures/demo_app`, without `Worker2`) against the current commit.
- Two more jobs exercise the "unstarted module" check from that same pair, covering both directions of `fail-on-relup-warnings`: one confirms the default (`false`) still succeeds with just the `::warning::`, the other confirms `true` turns that same warning into a failure.
- A negative test confirms identical `old-ref`/`new-ref` fails outright (no second version to relup between), and another confirms an `old-ref` that doesn't resolve to any commit fails with a clear reason rather than a raw git error.
- A final job exercises `upgrade-timeout-seconds` - the one failure mode no input value alone can force deterministically - using `RelupDemo.StuckWorker`, which casts itself into a `receive after :infinity` on boot and so can never acknowledge the suspend request a real upgrade sends it. That fixture lives on a dedicated `fixtures/stuck-worker` branch, not `main`: a hang landing on `main`, even transiently, risks hanging the whole self-test rather than just adding a warning the way `Worker2` does. `actions/checkout`'s own `fetch-depth: 0` fetches every branch and tag, not just the triggering ref's history, so this job can still resolve that branch's commits from a checkout of `main`.
- `shellcheck` runs against every script on every push.

Every job sets its own `timeout-minutes` (5 for the two that need no BEAM toolchain at all, 15 for the rest), rather than relying on GitHub's own 360-minute per-job default: `boot-timeout-seconds`/`upgrade-timeout-seconds` only bound the specific steps they wrap, not a hang somewhere outside them entirely, such as a toolchain download or a package registry outage.

## Releasing

```
make release VERSION=1.0.0
```

Tags the current commit `v1.0.0`, moves the floating `v1` tag to point at it too, and pushes both - the same convention `actions/checkout` and most of the GitHub Actions ecosystem use, so a consumer pinned to `@v1` picks up new `v1.x.y` releases automatically.

## References

- [`ferd/dandelion`](https://github.com/ferd/dandelion) - reference implementation of Erlang hot upgrades in containers, running an equivalent check on every pull request using `rebar3`/`relx`.
- [My Favorite Erlang Container](https://ferd.ca/my-favorite-erlang-container.html)
- [`Ahzed11/HotCI`](https://github.com/Ahzed11/HotCI) - a GitHub Actions template for rebar3/Erlang projects taking the same idea further: building old and new releases and running a `common_test` suite against both an upgrade and a downgrade.

## License

MIT, see [LICENSE.md](LICENSE.md).
