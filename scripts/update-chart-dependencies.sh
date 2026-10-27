#!/usr/bin/env bash
# Opens a pull request for every chart dependency with a newer stable version.
#
# For each dependency of each Chart.yaml under CHARTS_DIR that comes from a Helm repository
# (http(s)) or an OCI registry, the latest stable version (X, X.Y, X.Y.Z, optionally with a v) is
# looked up. When it is higher than the one in use, a branch bump/<chart>-<dependency>-<version> is
# created from BASE_BRANCH with the new dependency version and the chart's own version bumped by
# LABEL (bump-chart-versions.sh), and a pull request with that label is opened. The chart version
# is bumped here because pull requests opened with the workflow token do not run the checks that
# would otherwise bump it. A dependency that already has an open pull request, for this or an
# earlier version, is left alone until it is merged or closed.
#
# Environment:
#   BASE_BRANCH  branch to start from and to open the pull requests against (required)
#   LABEL        semver label of the pull requests and bump of the chart version (default: patch)
#   REVIEWERS    comma-separated GitHub users to request a review from (optional)
#   CHARTS_DIR   directory that holds one directory per chart (default: charts)
#   GH           gh binary (default: gh); CRANE crane binary (default: crane), for OCI registries
#   DRY_RUN      true to only report what would be done
#
# Requires git, yq (mikefarah, v4), curl, gh and, for OCI dependencies, crane. Git has to be able to
# push to origin and to commit (user.name and user.email).

set -euo pipefail

: "${BASE_BRANCH:?BASE_BRANCH must name the branch to update}"
LABEL="${LABEL:-patch}"
REVIEWERS="${REVIEWERS:-}"
CHARTS_DIR="${CHARTS_DIR:-charts}"
GH="${GH:-gh}"
CRANE="${CRANE:-crane}"
DRY_RUN="${DRY_RUN:-false}"
BUMP_SCRIPT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/bump-chart-versions.sh"
STABLE_VERSION_REGEX='^v?[0-9]+(\.[0-9]+)*$'

latest_version() {
    local name=$1 repository=$2
    case "$repository" in
        oci://*)
            "$CRANE" ls "${repository#oci://}/$name" 2>/dev/null ;;
        http://*|https://*|file://*)
            curl -fsSL "${repository%/}/index.yaml" | yq e ".entries.\"$name\"[].version" - ;;
    esac | grep -E "$STABLE_VERSION_REGEX" | sort -V | tail -n 1 || true
}

git fetch --quiet origin "$BASE_BRANCH"
git checkout --quiet --detach "origin/$BASE_BRANCH"

opened=0
for chart_file in "$CHARTS_DIR"/*/Chart.yaml; do
    [ -f "$chart_file" ] || continue
    chart=$(basename "$(dirname "$chart_file")")
    count=$(yq e '.dependencies | length' "$chart_file")

    for ((i = 0; i < count; i++)); do
        name=$(yq e ".dependencies[$i].name" "$chart_file")
        repository=$(yq e ".dependencies[$i].repository // \"\"" "$chart_file")
        current=$(yq e ".dependencies[$i].version" "$chart_file")

        case "$repository" in
            oci://*|http://*|https://*|file://*) ;;
            *) echo "$chart/$name: no Helm repository or OCI registry, skipping"; continue ;;
        esac

        latest=$(latest_version "$name" "$repository")
        if [ -z "$latest" ] || [ "$latest" = null ]; then
            echo "$chart/$name: no stable version found in $repository, skipping"
            continue
        fi
        if [ "$(printf '%s\n%s\n' "$current" "$latest" | sort -V | tail -n 1)" = "$current" ]; then
            echo "$chart/$name: $current is up to date"
            continue
        fi

        prefix="bump/$chart-$name-"
        if "$GH" pr list --state open --base "$BASE_BRANCH" --json headRefName --jq '.[].headRefName' \
            | grep -q "^${prefix}v\?[0-9]"; then
            echo "$chart/$name: $current -> $latest, but a pull request for it is already open"
            continue
        fi
        branch="$prefix$latest"
        if git ls-remote --exit-code --heads origin "$branch" >/dev/null 2>&1; then
            echo "$chart/$name: branch $branch already exists, skipping"
            continue
        fi

        title="chore(deps): bump $name to $latest in $chart"
        echo "$chart/$name: $current -> $latest"
        if [ "$DRY_RUN" = true ]; then
            continue
        fi

        git checkout --quiet -b "$branch" "origin/$BASE_BRANCH"
        yq e -i ".dependencies[$i].version = \"$latest\"" "$chart_file"
        git add "$chart_file"
        git commit --quiet -m "$title"
        BUMP="$LABEL" BASE_REF="$BASE_BRANCH" CHARTS_DIR="$CHARTS_DIR" GITHUB_OUTPUT="" "$BUMP_SCRIPT"
        git push --quiet origin "$branch"

        args=(--base "$BASE_BRANCH" --head "$branch" --title "$title" --label "$LABEL"
              --body "Bumps the \`$name\` dependency of the \`$chart\` chart from \`$current\` to \`$latest\`, and the chart version by \`$LABEL\`.")
        if [ -n "$REVIEWERS" ]; then
            args+=(--reviewer "$REVIEWERS")
        fi
        "$GH" pr create "${args[@]}"
        opened=$((opened + 1))

        git checkout --quiet --detach "origin/$BASE_BRANCH"
    done
done

echo "Opened $opened pull request(s)"
