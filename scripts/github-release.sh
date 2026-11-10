#!/usr/bin/env bash
# Publishes a GitHub release, tagging TARGET with VERSION.
#
# A pre-release replaces the release and the tag of the same name, if there are any: a pull request
# publishes the same X.Y.Z-PRE-<number> on every push. A release refuses to replace one: a version,
# once released, does not change. The release notes are generated from the merged pull requests.
#
# Environment:
#   VERSION     tag and name of the release (required)
#   TARGET      commit to tag (required)
#   PRERELEASE  true for a pre-release (default: false)
#   TITLE       title of the release (default: VERSION)
#   FILES       newline- or space-separated globs of the files to attach, relative to the current
#               directory; a glob that matches nothing fails
#   REPOSITORY  owner/repo (default: $GITHUB_REPOSITORY)
#   GH          gh binary (default: gh)

set -euo pipefail

: "${VERSION:?VERSION must name the release}"
: "${TARGET:?TARGET must name the commit to tag}"
PRERELEASE="${PRERELEASE:-false}"
TITLE="${TITLE:-$VERSION}"
FILES="${FILES:-}"
REPOSITORY="${REPOSITORY:-${GITHUB_REPOSITORY:?REPOSITORY or GITHUB_REPOSITORY must name the repository}}"
GH="${GH:-gh}"

case "$PRERELEASE" in
    true|false) ;;
    *) echo "::error::PRERELEASE must be true or false, got '$PRERELEASE'" >&2; exit 1 ;;
esac

# the globs are split without being expanded, so that a glob matching nothing is noticed
set -f
read -r -d '' -a patterns <<< "$FILES" || true
set +f
assets=()
shopt -s nullglob
for pattern in "${patterns[@]}"; do
    # shellcheck disable=SC2206 # the glob is expanded on purpose
    matches=($pattern)
    if [ "${#matches[@]}" -eq 0 ]; then
        echo "::error::No file matches '$pattern'" >&2
        exit 1
    fi
    assets+=("${matches[@]}")
done
shopt -u nullglob

release_exists=false
if "$GH" release view "$VERSION" --repo "$REPOSITORY" --json tagName >/dev/null 2>&1; then
    release_exists=true
fi
tag_exists=false
if "$GH" api "repos/$REPOSITORY/git/ref/tags/$VERSION" >/dev/null 2>&1; then
    tag_exists=true
fi

if [ "$release_exists" = true ] || [ "$tag_exists" = true ]; then
    if [ "$PRERELEASE" != true ]; then
        echo "::error::$VERSION already exists: a release is not replaced" >&2
        exit 1
    fi
    echo "Replacing the pre-release $VERSION"
    if [ "$release_exists" = true ]; then
        "$GH" release delete "$VERSION" --repo "$REPOSITORY" --yes
    fi
    if [ "$tag_exists" = true ]; then
        "$GH" api -X DELETE "repos/$REPOSITORY/git/refs/tags/$VERSION" >/dev/null
    fi
fi

args=(release create "$VERSION" --repo "$REPOSITORY" --target "$TARGET" --title "$TITLE" --generate-notes)
if [ "$PRERELEASE" = true ]; then
    args+=(--prerelease)
fi
"$GH" "${args[@]}" "${assets[@]}"
echo "Published $VERSION on $TARGET${assets:+ with ${#assets[@]} file(s)}"
