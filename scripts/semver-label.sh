#!/usr/bin/env bash
# Prints the semver bump (major, minor or patch) of a run from the label of its pull request.
#
# On a pull request, the labels it has now, not the ones of the event that started the run: a pull
# request opened by a bot gets its label right after it is opened. On a push, the labels of the
# merged pull request the pushed commit comes from. The pull request needs exactly one of the labels
# major, minor and patch. On a push, DEFAULT_BUMP, when set, is used instead of failing when no
# merged pull request contains the commit or it has no such label.
#
# Environment:
#   EVENT         pull_request or push (required)
#   PR            pull request number, on a pull request
#   SHA           pushed commit, on a push
#   DEFAULT_BUMP  major, minor or patch for a push without a labelled pull request (default: none)
#   REPOSITORY    owner/repo (default: $GITHUB_REPOSITORY)
#   GH            gh binary (default: gh)
#   GITHUB_OUTPUT when set, receives bump=<bump>

set -euo pipefail

: "${EVENT:?EVENT must be pull_request or push}"
DEFAULT_BUMP="${DEFAULT_BUMP:-}"
REPOSITORY="${REPOSITORY:-${GITHUB_REPOSITORY:?REPOSITORY or GITHUB_REPOSITORY must name the repository}}"
GH="${GH:-gh}"

case "$DEFAULT_BUMP" in
    ""|major|minor|patch) ;;
    *) echo "::error::DEFAULT_BUMP must be major, minor or patch, got '$DEFAULT_BUMP'" >&2; exit 1 ;;
esac

labels="[]"
if [ "$EVENT" = pull_request ] || [ "$EVENT" = pull_request_target ]; then
    : "${PR:?PR must be the pull request number}"
    labels=$("$GH" api "repos/$REPOSITORY/pulls/$PR" --jq '[.labels[].name]')
else
    : "${SHA:?SHA must be the pushed commit}"
    pr=$("$GH" api "repos/$REPOSITORY/commits/$SHA/pulls" \
        --jq '[.[] | select(.merged_at != null)][0] // empty | {number, labels: [.labels[].name]}')
    if [ -z "$pr" ]; then
        if [ -n "$DEFAULT_BUMP" ]; then
            echo "No merged pull request contains $SHA, releasing it as $DEFAULT_BUMP" >&2
            echo "bump=$DEFAULT_BUMP" >> "${GITHUB_OUTPUT:-/dev/null}"
            echo "$DEFAULT_BUMP"
            exit 0
        fi
        echo "::error::No merged pull request contains $SHA, so there is no semver label to release it with" >&2
        exit 1
    fi
    echo "Releasing pull request #$(jq -r .number <<< "$pr")" >&2
    labels=$(jq -c .labels <<< "$pr")
fi

bumps=$(jq -r '[.[] | select(. == "major" or . == "minor" or . == "patch")] | join(" ")' <<< "$labels")
if [ "$(wc -w <<< "$bumps")" -ne 1 ]; then
    if [ "$EVENT" = push ] && [ -z "$bumps" ] && [ -n "$DEFAULT_BUMP" ]; then
        echo "The pull request has no semver label, releasing it as $DEFAULT_BUMP" >&2
        bumps="$DEFAULT_BUMP"
    else
        echo "::error::The pull request needs exactly one of the labels major, minor or patch (found: ${bumps:-none})" >&2
        exit 1
    fi
fi

echo "bump=$bumps" >> "${GITHUB_OUTPUT:-/dev/null}"
echo "$bumps"
