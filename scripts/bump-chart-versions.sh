#!/usr/bin/env bash
# Bumps the version of every Helm chart a pull request changes and commits the result.
#
# Runs in a checkout of the pull request branch. For each chart directory under CHARTS_DIR that
# the pull request changes, the new version is the chart's version on the base branch bumped by
# BUMP. Starting from the base branch, and not from the branch itself, makes the result the same
# however many times the script runs. A chart that does not exist on the base branch keeps its
# version.
#
# Environment:
#   BUMP             major, minor or patch (required)
#   BASE_REF         base branch of the pull request, e.g. main (required)
#   BASE_REPOSITORY  where to fetch BASE_REF from: a remote name or URL (default: origin)
#   CHARTS_DIR       directory that holds one directory per chart (default: charts)
#   EXCLUDE          space-separated paths that never count as a chart change
#                    (default: $CHARTS_DIR/README.md)
#   GITHUB_OUTPUT    when set, receives committed=true|false, the bumped charts and the changed
#                    charts (changed=, also the ones whose version was already right)
#
# Requires git and yq (mikefarah, v4).

set -euo pipefail

: "${BUMP:?BUMP must be major, minor or patch}"
: "${BASE_REF:?BASE_REF must name the base branch}"
BASE_REPOSITORY="${BASE_REPOSITORY:-origin}"
CHARTS_DIR="${CHARTS_DIR:-charts}"
EXCLUDE="${EXCLUDE:-$CHARTS_DIR/README.md}"

case "$BUMP" in
    major|minor|patch) ;;
    *) echo "::error::Unknown bump '$BUMP', expected major, minor or patch" >&2; exit 1 ;;
esac

output() {
    if [ -n "${GITHUB_OUTPUT:-}" ]; then
        echo "$1" >> "$GITHUB_OUTPUT"
    fi
}

git fetch --quiet --no-tags "$BASE_REPOSITORY" "$BASE_REF"
base=$(git rev-parse FETCH_HEAD)

# charts touched by the pull request: the first directory level under CHARTS_DIR
declare -A charts=()
while IFS= read -r file; do
    [ -n "$file" ] || continue
    case " $EXCLUDE " in *" $file "*) continue ;; esac
    case "$file" in
        "$CHARTS_DIR"/*/*)
            rest="${file#"$CHARTS_DIR"/}"
            charts["${rest%%/*}"]=1
            ;;
    esac
done < <(git diff --name-only "$base...HEAD")

changed=$(printf '%s\n' "${!charts[@]}" | sort | xargs)
output "changed=$changed"

bumped=()
for chart in $changed; do
    chart_file="$CHARTS_DIR/$chart/Chart.yaml"
    if [ ! -f "$chart_file" ]; then
        echo "$chart has no Chart.yaml on the branch, skipping"
        continue
    fi
    if ! base_version=$(git show "$base:$chart_file" 2>/dev/null | yq e '.version' -); then
        echo "$chart is not on $BASE_REF yet, keeping its version"
        continue
    fi

    IFS=. read -r major minor patch <<< "${base_version%%[-+]*}"
    case "$BUMP" in
        major) major=$((major + 1)); minor=0; patch=0 ;;
        minor) minor=$((minor + 1)); patch=0 ;;
        patch) patch=$((patch + 1)) ;;
    esac
    version="$major.$minor.$patch"

    current=$(yq e '.version' "$chart_file")
    if [ "$current" = "$version" ]; then
        echo "$chart is already at $version ($base_version on $BASE_REF, $BUMP)"
        continue
    fi
    echo "$chart: $base_version on $BASE_REF -> $version ($BUMP), was $current on the branch"
    yq e -i ".version = \"$version\"" "$chart_file"
    bumped+=("$chart")
done

if [ "${#bumped[@]}" -eq 0 ]; then
    echo "Chart versions are up to date"
    output "committed=false"
    exit 0
fi

for chart in "${bumped[@]}"; do
    git add -- "$CHARTS_DIR/$chart/Chart.yaml"
done
bot_name="github-actions[bot]"
bot_email="41898282+github-actions[bot]@users.noreply.github.com"
GIT_AUTHOR_NAME="$bot_name" GIT_AUTHOR_EMAIL="$bot_email" \
    GIT_COMMITTER_NAME="$bot_name" GIT_COMMITTER_EMAIL="$bot_email" \
    git commit --quiet -m "Update helm chart versions"
git show --stat --format='%s' HEAD
output "committed=true"
output "charts=${bumped[*]}"
