#!/usr/bin/env bash
# Prints the next release version (X.Y.Z, without the prefix) of the repository in the current
# directory: its highest <prefix>X.Y.Z tag bumped by BUMP, or 0.0.0 bumped when there is none. Tags
# that are not plain <prefix>X.Y.Z, such as the moving major tags (v1) or pre-releases, are ignored.
#
# Environment:
#   BUMP        major, minor or patch (required)
#   TAG_PREFIX  text the release tags start with (default: v); empty for tags like 1.2.3

set -euo pipefail

: "${BUMP:?BUMP must be major, minor or patch}"

TAG_PREFIX="${TAG_PREFIX-v}"

latest=$(git tag --list "$TAG_PREFIX*" | while IFS= read -r tag; do
    version="${tag#"$TAG_PREFIX"}"
    if [[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        echo "$version"
    fi
done | sort -t. -k1,1n -k2,2n -k3,3n | tail -n 1 || true)
IFS=. read -r major minor patch <<< "${latest:-0.0.0}"

case "$BUMP" in
    major) major=$((major + 1)); minor=0; patch=0 ;;
    minor) minor=$((minor + 1)); patch=0 ;;
    patch) patch=$((patch + 1)) ;;
    *) echo "Unknown bump '$BUMP', expected major, minor or patch" >&2; exit 1 ;;
esac

echo "$major.$minor.$patch"
