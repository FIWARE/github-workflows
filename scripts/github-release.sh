#!/usr/bin/env bash
# Publishes a GitHub release, tagging TARGET with VERSION.
#
# A pre-release replaces the release and the tag of the same name, if there are any: a pull request
# publishes the same X.Y.Z-PRE-<number> on every push. A release refuses to replace one: a version,
# once released, does not change. The release notes are generated from the pull requests merged
# since the previous release of the same series: the highest <prefix>X.Y.Z tag below the version,
# where <prefix> is whatever precedes the version number (v in v1.2.3, nothing in 1.2.3). Without
# it, GitHub would start from its latest release, which can be one of another series, such as a
# chart release (<chart>-X.Y.Z) of the same repository.
#
# Environment:
#   VERSION     tag and name of the release (required)
#   TARGET      commit to tag (required)
#   PRERELEASE  true for a pre-release (default: false)
#   TITLE       title of the release (default: VERSION)
#   FILES       newline- or space-separated globs of the files to attach, relative to the current
#               directory; a glob that matches nothing fails
#   NOTES_START_TAG  tag the release notes start from (default: the previous release, see above;
#               none when there is no previous one)
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

# previous_release <version>: the highest <prefix>X.Y.Z tag of the repository below the X.Y.Z of the
# version, or nothing
previous_release() {
    local version=$1 prefix number
    prefix="${version%%[0-9]*}"
    number="${version#"$prefix"}"
    number="${number%%[-+]*}"
    "$GH" api --paginate "repos/$REPOSITORY/tags" --jq '.[].name' \
        | while IFS= read -r tag; do
            case "$tag" in "$prefix"*) ;; *) continue ;; esac
            candidate="${tag#"$prefix"}"
            [[ "$candidate" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || continue
            # keep the candidates below the version
            if [ "$(printf '%s\n%s\n' "$candidate" "$number" | sort -t. -k1,1n -k2,2n -k3,3n | head -n 1)" = "$candidate" ] \
                && [ "$candidate" != "$number" ]; then
                echo "$candidate"
            fi
        done \
        | sort -t. -k1,1n -k2,2n -k3,3n | tail -n 1 | sed "s/^/$prefix/"
}

NOTES_START_TAG="${NOTES_START_TAG-$(previous_release "$VERSION")}"

args=(release create "$VERSION" --repo "$REPOSITORY" --target "$TARGET" --title "$TITLE" --generate-notes)
if [ -n "$NOTES_START_TAG" ]; then
    echo "Release notes start from $NOTES_START_TAG"
    args+=(--notes-start-tag "$NOTES_START_TAG")
fi
if [ "$PRERELEASE" = true ]; then
    args+=(--prerelease)
fi
"$GH" "${args[@]}" "${assets[@]}"
echo "Published $VERSION on $TARGET${assets:+ with ${#assets[@]} file(s)}"
