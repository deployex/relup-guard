#!/usr/bin/env bash
set -euo pipefail

# Appends a short, build-only suffix (derived from REF, so old-ref and
# new-ref always get a different one) to every Mix app's own version this
# project defines, plus whatever version: the release itself falls back
# to, so a relup has something real to diff even when nobody bumped a
# version by hand for this change. Only ever touches the ephemeral
# checkout build-release.sh's own `git checkout --force` just produced,
# never anything committed - and runs unconditionally, on both old-ref
# and new-ref, rather than reacting after the fact to the two resolving
# to the same version: by the time that would be noticed, the in-place
# rebuild has already overwritten old-ref's own _build/<env>/rel/<name>/
# tree, with nothing left to diff against.
#
# build-release.sh sources this file - rather than executing it as a
# separate process - specifically so it can do so BEFORE its own
# `git checkout --force "$REF"`. This repo's own CI builds its fixture
# app from inside this same repository (old-ref/new-ref are commits in
# relup-guard-elixir's own history, not a separate consumer repo's), so
# checking out an old-ref that predates this file would otherwise
# delete it from disk before a later, separate `patch-version.sh`
# process invocation could even start - a real consumer never hits
# this, since its own checkout never touches the action's own files,
# which live under a separate, already-resolved action_path.
#
# REF, WORKING_DIRECTORY, and SUFFIX are build-release.sh's own
# variables, already set by the time it sources this file - defining
# the function below against them here, rather than re-declaring them
# as this script's own positional parameters, is what makes sourcing
# before the checkout equivalent to running this as its own process
# after it.

# A plain recursive search for mix.exs covers a single app (just the
# root mix.exs) and an umbrella (the root umbrella mix.exs, which a
# release with no explicit `version:` of its own falls back to, plus
# each apps/*/mix.exs) alike, with no need to tell which shape a given
# project uses - excluding _build/deps/.git keeps it from also
# "patching" a fetched dependency's own vendored mix.exs, which isn't
# this project's to change and isn't what a relup here is about anyway.
#
# Every `version:` line in a given mix.exs is patched, not just the
# first - an umbrella root's mix.exs can carry both its own
# project-level version AND a `releases: [name: [version: "..."]]`
# override for a specific release, and both need the same suffix.
patch_mix_versions() {
  local f line rhs literal helper_match helper_file helper_literal
  local attr_name attr_match attr_literal

  while IFS= read -r -d '' f; do
    while IFS= read -r line; do
      rhs="$(echo "$line" | sed -E 's/^[^:]*version:[[:space:]]*//; s/,?[[:space:]]*$//')"

      case "$rhs" in
        \"*\")
          literal="${rhs#\"}"
          literal="${literal%\"}"

          case "$literal" in
            *+*)
              # Already carries a suffix of its own - leave it alone
              # rather than stacking another suffix onto it.
              ;;
            *)
              perl -i -pe "s/version:(\\s*)\"\\Q${literal}\\E\"/version:\\1\"${literal}+${SUFFIX}\"/" "$f"
              echo "Patched ${f}: version ${literal} -> ${literal}+${SUFFIX}"
              ;;
          esac
          ;;
        "{:from_app,"*)
          # Delegates to a specific app's own version, which gets its
          # own pass through this same loop when that app's mix.exs is
          # visited - nothing to do here.
          ;;
        @[a-zA-Z_]*)
          # A module attribute (e.g. `version: @version`, with
          # `@version "0.2.0"` set earlier in the same module) - look
          # for where that attribute itself is assigned a literal, in
          # this same file (module attributes aren't visible outside
          # the module that sets them, so there's no point searching
          # elsewhere), and patch that instead.
          attr_name="${rhs#@}"
          attr_match="$(grep -E "^\\s*@${attr_name}\\s+\"[^\"]*\"" "$f" | head -1 || true)"

          if [ -z "$attr_match" ]; then
            echo "::warning::${f} sets version: ${rhs}, but no '@${attr_name} \"...\"' assignment was found in the same file to patch instead - leaving it as-is. If ${rhs} isn't already unique per commit on its own, old-ref and new-ref may collide; the later 'Expected exactly one release tarball' check will catch that if so."
            continue
          fi

          attr_literal="$(echo "$attr_match" | grep -oE '"[^"]*"' | tail -1 | tr -d '"')"

          case "$attr_literal" in
            *+*) ;;
            *)
              perl -i -pe "s/(\\@${attr_name}\\s+)\"\\Q${attr_literal}\\E\"/\\1\"${attr_literal}+${SUFFIX}\"/" "$f"
              echo "Patched ${f}: version ${attr_literal} -> ${attr_literal}+${SUFFIX} (resolved from its own version: ${rhs})"
              ;;
          esac
          ;;
        *)
          # Not a literal, a module attribute, or a {:from_app, ...}
          # delegation - e.g. a call like Mix.Shared.version(). Find
          # where that's actually defined (a `def version, do: "..."` -
          # the idiom this repo's own fixtures and reference project
          # use) and patch the literal there instead, once per distinct
          # helper regardless of how many mix.exs files call it: the
          # second and later callers re-read the helper file fresh each
          # time, see it already contains "+" from the first call, and
          # skip it via the same guard as the literal branch above.
          #
          # `|| true` on this grep matters: with no match anywhere (a
          # version: this script genuinely can't resolve, e.g. one read
          # from a file at compile time), grep's own exit code is 1,
          # and piped through further greps under this script's own
          # `set -euo pipefail`, that would otherwise abort the whole
          # script right here instead of falling through to the
          # warning below.
          helper_match="$( (grep -rnE 'def[[:space:]]+version(\(\))?,?[[:space:]]*do:?[[:space:]]*"[^"]*"' \
            --include='*.ex' --include='*.exs' "$WORKING_DIRECTORY" \
            2>/dev/null | grep -vE '/(_build|deps)/' | head -1) || true)"

          if [ -z "$helper_match" ]; then
            echo "::warning::${f} sets version: ${rhs}, which isn't a plain string literal, a module attribute, or a {:from_app, ...} delegation, and no 'def version, do: \"...\"' helper was found to patch instead - leaving it as-is. If ${rhs} isn't already unique per commit on its own (e.g. read from a file that itself needs bumping), old-ref and new-ref may collide; the later 'Expected exactly one release tarball' check will catch that if so."
            continue
          fi

          helper_file="${helper_match%%:*}"
          helper_literal="$(echo "$helper_match" | grep -oE '"[^"]*"' | tail -1 | tr -d '"')"

          case "$helper_literal" in
            *+*) ;;
            *)
              perl -i -pe "s/(def\\s+version(\\(\\))?,?\\s*do:?\\s*)\"\\Q${helper_literal}\\E\"/\\1\"${helper_literal}+${SUFFIX}\"/" "$helper_file"
              echo "Patched ${helper_file}: version ${helper_literal} -> ${helper_literal}+${SUFFIX} (resolved from $(basename "$f")'s version: ${rhs})"
              ;;
          esac
          ;;
      esac
    done < <(grep -E '^\s*version:' "$f" || true)
  done < <(find "$WORKING_DIRECTORY" \
    \( -path '*/_build' -o -path '*/deps' -o -path '*/.git' \) -prune \
    -o -name 'mix.exs' -print0)
}
