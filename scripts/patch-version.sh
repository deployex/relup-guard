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
REF="$1"
WORKING_DIRECTORY="${2:-.}"

SUFFIX="${REF:0:12}"

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
        *)
          # Not a literal - e.g. a call like Mix.Shared.version(). Find
          # where that's actually defined (a `def version, do: "..."` -
          # the idiom this repo's own fixtures and reference project
          # use) and patch the literal there instead, once per distinct
          # helper regardless of how many mix.exs files call it: the
          # second and later callers re-read the helper file fresh each
          # time, see it already contains "+" from the first call, and
          # skip it via the same guard as the literal branch above.
          helper_match="$(grep -rnE 'def[[:space:]]+version(\(\))?,?[[:space:]]*do:?[[:space:]]*"[^"]*"' \
            --include='*.ex' --include='*.exs' "$WORKING_DIRECTORY" \
            2>/dev/null | grep -vE '/(_build|deps)/' | head -1)"

          if [ -z "$helper_match" ]; then
            echo "Notice: ${f} sets version: ${rhs}, which isn't a plain string literal and no 'def version, do: \"...\"' helper was found to patch instead - assuming it's already derived dynamically (e.g. from git describe) and already unique per commit."
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

patch_mix_versions
