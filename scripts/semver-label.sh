#!/usr/bin/env bash
# Prints the semver bump (major, minor or patch) of a run from the label of its pull request.
#
# On a pull request, the labels it has now, not the ones of the event that started the run: a pull
# request opened by a bot gets its label right after it is opened. On a push, the labels of the
# merged pull request the pushed commit comes from. The pull request needs exactly one of the labels
# major, minor and patch. On a push, DEFAULT_BUMP, when set, is used instead of failing when no
# merged pull request contains the commit or it has no such label.
#
# The GitHub API calls are retried: a transient error answers with an HTML page or a 5xx. When they
# keep failing, the script exits with 2, and with 1 when the label is the problem; only then it also
# writes label-missing=true, so that the caller asks for the label only when it is missing.
#
# Environment:
#   EVENT         pull_request or push (required)
#   PR            pull request number, on a pull request
#   SHA           pushed commit, on a push
#   DEFAULT_BUMP  major, minor or patch for a push without a labelled pull request (default: none)
#   REPOSITORY    owner/repo (default: $GITHUB_REPOSITORY)
#   GH            gh binary (default: gh)
#   RETRIES       attempts of each GitHub API call (default: 3)
#   RETRY_DELAY   seconds between them (default: 5)
#   GITHUB_OUTPUT when set, receives bump=<bump>, or label-missing=true

set -euo pipefail

: "${EVENT:?EVENT must be pull_request or push}"
DEFAULT_BUMP="${DEFAULT_BUMP:-}"
REPOSITORY="${REPOSITORY:-${GITHUB_REPOSITORY:?REPOSITORY or GITHUB_REPOSITORY must name the repository}}"
GH="${GH:-gh}"
RETRIES="${RETRIES:-3}"
RETRY_DELAY="${RETRY_DELAY:-5}"

case "$DEFAULT_BUMP" in
    ""|major|minor|patch) ;;
    *) echo "::error::DEFAULT_BUMP must be major, minor or patch, got '$DEFAULT_BUMP'" >&2; exit 1 ;;
esac

# api <gh api arguments>: prints the response, retrying the call
api() {
    local attempt response
    for ((attempt = 1; attempt <= RETRIES; attempt++)); do
        if response=$("$GH" api "$@"); then
            printf '%s\n' "$response"
            return 0
        fi
        if [ "$attempt" -lt "$RETRIES" ]; then
            echo "The GitHub API call failed (attempt $attempt of $RETRIES), retrying in ${RETRY_DELAY}s" >&2
            sleep "$RETRY_DELAY"
        fi
    done
    echo "::error::The GitHub API call failed $RETRIES times, so the semver label could not be read" >&2
    return 1
}

# label_missing <message>: fails because of the label itself
label_missing() {
    echo "::error::$1" >&2
    echo "label-missing=true" >> "${GITHUB_OUTPUT:-/dev/null}"
    exit 1
}

labels="[]"
if [ "$EVENT" = pull_request ] || [ "$EVENT" = pull_request_target ]; then
    : "${PR:?PR must be the pull request number}"
    labels=$(api "repos/$REPOSITORY/pulls/$PR" --jq '[.labels[].name]') || exit 2
else
    : "${SHA:?SHA must be the pushed commit}"
    pr=$(api "repos/$REPOSITORY/commits/$SHA/pulls" \
        --jq '[.[] | select(.merged_at != null)][0] // empty | {number, labels: [.labels[].name]}') || exit 2
    if [ -z "$pr" ]; then
        if [ -n "$DEFAULT_BUMP" ]; then
            echo "No merged pull request contains $SHA, releasing it as $DEFAULT_BUMP" >&2
            echo "bump=$DEFAULT_BUMP" >> "${GITHUB_OUTPUT:-/dev/null}"
            echo "$DEFAULT_BUMP"
            exit 0
        fi
        label_missing "No merged pull request contains $SHA, so there is no semver label to release it with"
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
        label_missing "The pull request needs exactly one of the labels major, minor or patch (found: ${bumps:-none})"
    fi
fi

echo "bump=$bumps" >> "${GITHUB_OUTPUT:-/dev/null}"
echo "$bumps"
