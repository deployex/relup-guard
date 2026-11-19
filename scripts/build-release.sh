#!/usr/bin/env bash
set -euo pipefail

# Checks out REF *in place* (no worktree) and builds the release there.
#
# Jellyfish's appup generator (and most Mix-release appup/relup tooling)
# finds the "previous version" to diff against by looking inside the same
# _build/<env>/rel/<name>/ tree a previous build already populated - not
# from git history directly. So old-ref and new-ref must be built
# sequentially in the same working directory/_build, rather than in
# isolated worktrees.
REF="$1"
RELEASE_NAME="$2"
MIX_ENV_VALUE="$3"
BUILD_COMMAND="${4:-mix deps.get && mix release}"
EXCLUDE_TARBALL="${5:-}"
WORKING_DIRECTORY="${6:-.}"

git checkout --force "$REF"

cd "$WORKING_DIRECTORY" || exit 1
export MIX_ENV="$MIX_ENV_VALUE"
bash -euo pipefail -c "$BUILD_COMMAND"

# A glob with nullglob, not `ls` piped through a read loop: parsing ls
# output breaks on filenames with spaces or newlines (shellcheck SC2012),
# and nullglob makes a no-match case an empty array instead of a literal
# unexpanded pattern, with no separate 2>/dev/null-and-swallow needed.
shopt -s nullglob
CANDIDATES=("_build/${MIX_ENV_VALUE}/${RELEASE_NAME}"-*.tar.gz)
shopt -u nullglob

NEW_CANDIDATES=()
if [ "${#CANDIDATES[@]}" -gt 0 ]; then
  # Bash <4.4 (still the /usr/bin/bash shipped on macOS) treats a bare
  # "${arr[@]}" expansion of a zero-element array as an unbound variable
  # under set -u, even though the array itself is perfectly well-defined -
  # guarding on the count first avoids ever performing that expansion when
  # CANDIDATES came back empty (no tarball at all is itself a real, and
  # fairly common, case: the version wasn't bumped so nullglob matched
  # nothing new).
  for f in "${CANDIDATES[@]}"; do
    ABS_F="$(cd "$(dirname "$f")" && pwd)/$(basename "$f")"
    if [ "$ABS_F" != "$EXCLUDE_TARBALL" ]; then
      NEW_CANDIDATES+=("$ABS_F")
    fi
  done
fi

if [ "${#NEW_CANDIDATES[@]}" -ne 1 ]; then
  echo "::error title=Expected exactly one release tarball::_build/${MIX_ENV_VALUE} for '${RELEASE_NAME}' at ${REF} matched ${#NEW_CANDIDATES[@]} tarball(s): ${NEW_CANDIDATES[*]:-none}. Check that mix.exs releases[:${RELEASE_NAME}][:steps] includes :tar, and that the version was actually bumped."
  exit 1
fi

ABS_TARBALL="${NEW_CANDIDATES[0]}"
BASENAME=$(basename "$ABS_TARBALL")
VERSION=${BASENAME#"${RELEASE_NAME}-"}
VERSION=${VERSION%.tar.gz}

echo "Built ${RELEASE_NAME} ${VERSION} from ${REF} -> ${ABS_TARBALL}"

if [ -n "${GITHUB_OUTPUT:-}" ]; then
  {
    echo "version=${VERSION}"
    echo "tarball=${ABS_TARBALL}"
  } >> "$GITHUB_OUTPUT"
fi
