#!/usr/bin/env bash
set -euo pipefail

RELEASE_NAME="$1"
OLD_TARBALL="$2"
NEW_TARBALL="$3"
OLD_VERSION="$4"
NEW_VERSION="$5"
BOOT_TIMEOUT="${6:-30}"
UPGRADE_TIMEOUT="${7:-60}"
FAIL_ON_WARNINGS="${8:-false}"

# Validated up front rather than left to whatever happens to consume them
# later. A non-numeric boot-timeout-seconds (e.g. a typo) hits bash
# arithmetic context's own "bare word is a nested variable reference"
# rule in the `for ((...))` loop below - an unset variable evaluates to
# 0, so the loop silently never runs even once, exactly like the
# deliberate boot-timeout-seconds: "0" case, but for an input that was
# never meant to mean that. A non-numeric upgrade-timeout-seconds
# instead reaches timeout(1) itself, which fails with "duration is not
# a number" and exit 125 - a value this script doesn't recognize as the
# timeout case (only 124 is), so it would otherwise fall through to the
# generic "Hot upgrade failed" error with the real cause buried in the
# echoed rpc output rather than named directly.
for pair in "boot-timeout-seconds:${BOOT_TIMEOUT}" "upgrade-timeout-seconds:${UPGRADE_TIMEOUT}"; do
  name="${pair%%:*}"
  value="${pair#*:}"
  if ! [[ "$value" =~ ^[0-9]+$ ]]; then
    echo "::error title=Invalid ${name}::'${value}' is not a non-negative integer."
    exit 1
  fi
done

EXTRACT_DIR=$(mktemp -d "${RUNNER_TEMP:-/tmp}/relup-guard-old.XXXXXX")
tar -xzf "$OLD_TARBALL" -C "$EXTRACT_DIR"

# Unique per invocation, not just the cookie: a fixed node name is fine on
# GitHub-hosted runners (a fresh VM per job), but BEAM toolchains are heavy
# enough that plenty of consumers run this on a reused self-hosted runner,
# where a fixed "relup_guard_old@127.0.0.1" would collide with a second
# job's node of the same name under the same epmd.
UNIQUE_SUFFIX="$(date +%s)_$$"
export RELEASE_COOKIE="relup-guard-${UNIQUE_SUFFIX}"
export RELEASE_NODE="relup_guard_old_${UNIQUE_SUFFIX}@127.0.0.1"
export RELEASE_DISTRIBUTION="name"

cd "$EXTRACT_DIR" || exit 1

# Erlang distribution binds to ALL interfaces once a node name is set,
# regardless of what hostname the node name itself uses - the "@127.0.0.1"
# in RELEASE_NODE only affects addressing, not which interfaces the
# listener actually accepts connections on (see Erlang/OTP's own security
# hardening guide: security.erlef.org/secure_coding_and_deployment_hardening/distribution).
# Harmless on a GitHub-hosted runner (a fresh, isolated VM per job); on a
# self-hosted runner sharing a network with other machines, it's a real,
# if short-lived, window where this node's distribution port is reachable
# network-wide, guarded only by a cookie that - unlike a real production
# cookie - is just a timestamp and pid, not meant to resist a guess.
# Appending rather than replacing, so any customization already in a
# consumer's own vm.args/remote.vm.args survives; both files exist by
# default even when empty of active directives. remote.vm.args covers the
# ephemeral client node the "rpc" subcommand spins up for each call below.
for vm_args_file in "releases/${OLD_VERSION}/vm.args" "releases/${OLD_VERSION}/remote.vm.args"; do
  if [ -f "$vm_args_file" ]; then
    echo '-kernel inet_dist_use_interface {127,0,0,1}' >> "$vm_args_file"
  fi
done

cleanup() {
  ./bin/"${RELEASE_NAME}" stop >/dev/null 2>&1 || true
}
trap cleanup EXIT

echo "Booting old release (${OLD_VERSION}) as a daemon..."
./bin/"${RELEASE_NAME}" daemon

echo "Waiting for ${RELEASE_NAME} to come up (timeout ${BOOT_TIMEOUT}s)..."
booted=false
for ((i = 1; i <= BOOT_TIMEOUT; i++)); do
  if ./bin/"${RELEASE_NAME}" pid >/dev/null 2>&1; then
    booted=true
    break
  fi
  sleep 1
done

if [ "$booted" != true ]; then
  echo "::error title=Release did not boot::${RELEASE_NAME} did not boot within ${BOOT_TIMEOUT}s."
  exit 1
fi
echo "Node is up."

# The whole point of a hot upgrade is that the running OS process never
# restarts - only its code does. Capturing the OS pid now and comparing it
# after the upgrade is the same idea as a blue/green or canary health check
# verifying the thing that actually happened rather than trusting the
# deploy tool's own reported status: a relup that quietly restarts the
# emulator (a stray restart_new_emulator/restart_emulator instruction, or
# an init system/supervisor restarting a crashed node) can still leave
# which_releases/0 reporting the new version as permanent, so that alone
# does not prove this was a hot swap rather than a disguised restart.
OLD_OS_PID=$(./bin/"${RELEASE_NAME}" pid)
echo "OS pid before upgrade: ${OLD_OS_PID}"

mkdir -p releases
cp "$NEW_TARBALL" releases/
NEW_TARBALL_BASENAME=$(basename "$NEW_TARBALL")
UNPACK_NAME=${NEW_TARBALL_BASENAME%.tar.gz}

# Unpacking places the new release's .rel and lib/<app>-<new_vsn>/ebin
# alongside the old ones on the already-running node, which is the
# precondition systools:make_relup needs to find the .appup files and
# synthesize the relup - Jellyfish (and most Mix appup tooling) never
# ships a pre-built relup in the tarball, only the appups.
#
# unpack_release(Name) looks inside the tarball for releases/<Name>.rel,
# so Name has to be the tarball's own basename without .tar.gz
# (<release-name>-<version>, e.g. "my_app-0.2.0") - that flat .rel file is
# exactly what Jellyfish.generate/1 copies into the release for this.
#
# Reports a sentinel string instead of trusting the rpc subcommand's exit
# code, since a raised exception on the *remote* node must never be
# allowed to System.halt it.
RPC_EXPR=$(cat <<EOF
unpack_name = ~c"${UNPACK_NAME}"
new_vsn = ~c"${NEW_VERSION}"
old_vsn = ~c"${OLD_VERSION}"
rel_name = ~c"${RELEASE_NAME}"

try do
  modules_loaded_before_upgrade = for {m, _} <- :code.all_loaded(), into: MapSet.new(), do: m

  case :release_handler.unpack_release(unpack_name) do
    {:ok, _} ->
      :ok

    {:error, {:enoent, path}} ->
      raise "unpack_release failed: #{path} does not exist. release_handler:unpack_release/1 needs a FLAT releases/<name>-<vsn>.rel file inside the tarball - a plain mix release only produces the nested releases/<vsn>/<name>.rel, not this one. Add a release step that copies it there (e.g. &Jellyfish.generate/1, which does this as well as generating .appup files)."

    {:error, reason} ->
      raise "unpack_release failed: #{inspect(reason)}"
  end

  root = :code.root_dir()
  new_rel = root ++ ~c"/releases/" ++ new_vsn ++ ~c"/" ++ rel_name
  old_rel = root ++ ~c"/releases/" ++ old_vsn ++ ~c"/" ++ rel_name
  lib_glob = root ++ ~c"/lib/*/ebin"
  out_dir = root ++ ~c"/releases/" ++ new_vsn

  case :systools.make_relup(new_rel, [old_rel], [old_rel], [:silent, {:path, [lib_glob]}, {:outdir, out_dir}]) do
    {:ok, relup, mod, warnings} ->
      if warnings != [] do
        # :silent only suppresses systools' own stdout chatter, not the
        # Warnings it still returns. A relup that "succeeds" with warnings
        # often means systools fell back to a cruder instruction than
        # intended (e.g. a dependency's version bumped with no .appup, so
        # it just reloads everything) rather than the precise one-module
        # code_change a reviewer would expect to see.
        formatted =
          warnings
          |> Enum.map_join("; ", fn w -> IO.iodata_to_binary(mod.format_warning(w)) end)
          |> String.replace("\n", " ")
          |> String.trim()

        IO.puts("RELUP_GUARD_WARNINGS: #{formatted}")
      end

      # systools returning :ok with zero warnings does NOT mean a brand
      # new module got wired into a running supervisor. The per-app .appup
      # fragment Jellyfish generates for a genuinely new module tags it
      # {add_module, Mod}, but systools:make_relup/4 does not preserve
      # that tag in the compiled relup script - it folds the new module
      # into the same {load, {Mod, brutal_purge, brutal_purge}} +
      # load_object_code instructions used for every other changed
      # module, with nothing in the relup itself marking it as "new". So
      # "new" has to be determined by comparing against what this running
      # node actually had loaded before the upgrade, not by scanning
      # instruction tags.
      #
      # The OTP appup cookbook is explicit that starting a new supervised
      # child needs its own :apply instruction (e.g. supervisor:start_child)
      # in the same upgrade script - load/load_object_code only loads code,
      # it never starts anything. A newly-loaded module with no :apply
      # anywhere in the script is indistinguishable, from relup-guard's
      # position, between "a new non-process module that needs nothing
      # more" (safe) and "a new supervised child whose appup generator
      # never emitted the apply to actually start it" (not safe).
      {_vsn, up_from_scripts, _down_to_scripts} = relup

      instructions =
        case List.keyfind(up_from_scripts, old_vsn, 0) do
          {_from_vsn, _descr, instrs} -> instrs
          nil -> []
        end

      loaded_by_relup =
        for {:load_object_code, {_app, _vsn, mods}} <- instructions,
            mod <- mods,
            into: MapSet.new(),
            do: mod

      new_modules = MapSet.difference(loaded_by_relup, modules_loaded_before_upgrade)
      has_apply = Enum.any?(instructions, &match?({:apply, _}, &1))

      if MapSet.size(new_modules) > 0 and not has_apply do
        mods_str = new_modules |> Enum.sort() |> Enum.map_join(", ", &inspect/1)
        IO.puts("RELUP_GUARD_UNSTARTED_MODULES: #{mods_str}")
      end

    {:error, mod, error} ->
      raise "systools:make_relup failed: #{IO.iodata_to_binary(mod.format_error(error))}"
  end

  {:ok, _, _} = :release_handler.check_install_release(new_vsn)

  case :release_handler.install_release(new_vsn, []) do
    {:ok, _, _} -> :ok
    {:continue_after_restart, _, _} -> :ok
  end

  :ok = :release_handler.make_permanent(new_vsn)

  releases = :release_handler.which_releases()
  match = Enum.find(releases, fn {_name, v, _apps, status} -> v == new_vsn and status == :permanent end)

  if match do
    IO.puts("RELUP_GUARD_OK")
  else
    IO.puts("RELUP_GUARD_FAIL: new version not permanent after install, which_releases=#{inspect(releases)}")
  end
rescue
  e -> IO.puts("RELUP_GUARD_FAIL: #{Exception.format(:error, e, __STACKTRACE__)}")
catch
  kind, reason -> IO.puts("RELUP_GUARD_FAIL: #{inspect(kind)} #{inspect(reason)}")
end
EOF
)

echo "Synthesizing and applying the upgrade ${OLD_VERSION} -> ${NEW_VERSION} (timeout ${UPGRADE_TIMEOUT}s)..."

# Bounded with timeout(1) rather than left to the caller's own job-level
# timeout (GitHub Actions defaults to 360 minutes): a hang here is almost
# always release_handler waiting on a process that never acknowledges a
# suspend/code_change, or a deadlocked supervisor - the same class of bug
# a Kubernetes readinessProbe or a blue/green health check is built to
# catch fast rather than let run out the clock.
set +e
RPC_OUTPUT=$(timeout "${UPGRADE_TIMEOUT}" ./bin/"${RELEASE_NAME}" rpc "$RPC_EXPR" 2>&1)
RPC_EXIT=$?
set -e
echo "$RPC_OUTPUT"

if [ "$RPC_EXIT" -eq 124 ]; then
  echo "::error title=Hot upgrade timed out::Hot upgrade to ${NEW_VERSION} did not complete within ${UPGRADE_TIMEOUT}s and was killed. This usually means systools:make_relup or release_handler:install_release hung (e.g. a process not acknowledging code_change) rather than failing cleanly - raise the upgrade-timeout-seconds input if your release is just slow, otherwise treat this as a bug in the upgrade path itself."
  exit 1
fi

if ! echo "$RPC_OUTPUT" | grep -q "RELUP_GUARD_OK"; then
  echo "::error title=Hot upgrade failed::Hot upgrade to ${NEW_VERSION} failed. See the rpc output above for the root cause."
  exit 1
fi

RELUP_WARNINGS=$(echo "$RPC_OUTPUT" | grep "RELUP_GUARD_WARNINGS:" | sed 's/^RELUP_GUARD_WARNINGS: //' || true)
if [ -n "$RELUP_WARNINGS" ]; then
  if [ "$FAIL_ON_WARNINGS" = "true" ]; then
    echo "::error title=systools reported relup warnings (fail-on-warnings is true)::${RELUP_WARNINGS}"
    exit 1
  fi
  echo "::warning title=systools reported relup warnings::${RELUP_WARNINGS}"
fi

UNSTARTED_MODULES=$(echo "$RPC_OUTPUT" | grep "RELUP_GUARD_UNSTARTED_MODULES:" | sed 's/^RELUP_GUARD_UNSTARTED_MODULES: //' || true)
if [ -n "$UNSTARTED_MODULES" ]; then
  MESSAGE="The relup loads ${UNSTARTED_MODULES} but has no :apply instruction anywhere in this upgrade script. If any of these are meant to run as a new supervised process (not just be loaded as code - e.g. a new GenServer added as a supervisor child), it will NOT actually be started: 'add_module' only loads the code, starting a new child needs its own explicit apply instruction (e.g. supervisor:start_child), same as the OTP appup cookbook's documented pattern for this exact case. If these are ordinary new modules that nothing needs to start, this is expected and safe to ignore."
  if [ "$FAIL_ON_WARNINGS" = "true" ]; then
    echo "::error title=Relup may not start new supervised children (fail-on-warnings is true)::${MESSAGE}"
    exit 1
  fi
  echo "::warning title=Relup may not start new supervised children::${MESSAGE}"
fi

NEW_OS_PID=$(./bin/"${RELEASE_NAME}" pid 2>/dev/null || true)
if [ -z "$NEW_OS_PID" ] || [ "$NEW_OS_PID" != "$OLD_OS_PID" ]; then
  echo "::error title=Node restarted during upgrade::The OS process id changed from ${OLD_OS_PID} to ${NEW_OS_PID:-<gone>} while applying the upgrade. release_handler reported the upgrade as successful, but the node was actually restarted rather than hot-upgraded in place - any running state this appup wasn't told to carry forward (GenServer state outside code_change, ETS tables, timers, in-flight requests) was lost exactly as it would be on a full deploy."
  exit 1
fi
echo "OS pid unchanged (${OLD_OS_PID}): confirmed this was a hot code swap, not a restart."

# Only reachable with fail-on-relup-warnings left false (true exits above
# instead), so a warning here means the job's own overall status will
# read "success" - which, without this, would look identical in the job
# summary to a run with no warnings at all. The whole point of that
# summary is being visible at a glance without opening step logs; a
# warning that only shows up by opening them anyway defeats that.
if [ -n "${GITHUB_OUTPUT:-}" ]; then
  if [ -n "$RELUP_WARNINGS" ] || [ -n "$UNSTARTED_MODULES" ]; then
    echo "had-warnings=true" >> "$GITHUB_OUTPUT"
  else
    echo "had-warnings=false" >> "$GITHUB_OUTPUT"
  fi
fi

echo "Hot upgrade to ${NEW_VERSION} succeeded."
