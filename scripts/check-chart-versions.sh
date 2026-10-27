#!/usr/bin/env bash
# Fails when a push changes a Helm chart without changing its version.
#
# Such a chart would never be released: chart-releaser skips the versions that are already
# published, so the change would reach the repository but no package. This check runs before the
# release, on the commits the push brought in (BEFORE..AFTER). Charts that are new or were deleted
# in the push are not checked.
#
# Environment:
#   BEFORE      commit before the push; empty or all zeros checks nothing (a new branch)
#   AFTER       commit after the push (default: HEAD)
#   CHARTS_DIR  directory that holds one directory per chart (default: charts)
#   EXCLUDE     space-separated paths that never count as a chart change
#               (default: $CHARTS_DIR/README.md)
#
# Requires git and yq (mikefarah, v4).

set -euo pipefail

BEFORE="${BEFORE:-}"
AFTER="${AFTER:-HEAD}"
CHARTS_DIR="${CHARTS_DIR:-charts}"
EXCLUDE="${EXCLUDE:-$CHARTS_DIR/README.md}"

if [ -z "$BEFORE" ] || [ -z "${BEFORE//0/}" ]; then
    echo "No previous commit to compare with, nothing to check"
    exit 0
fi

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
done < <(git diff --name-only "$BEFORE" "$AFTER")

unreleased=()
for chart in $(printf '%s\n' "${!charts[@]}" | sort); do
    chart_file="$CHARTS_DIR/$chart/Chart.yaml"
    if ! after=$(git show "$AFTER:$chart_file" 2>/dev/null | yq e '.version' -); then
        echo "$chart was removed, nothing to check"
        continue
    fi
    if ! before=$(git show "$BEFORE:$chart_file" 2>/dev/null | yq e '.version' -); then
        echo "$chart is new, at $after"
        continue
    fi
    if [ "$before" = "$after" ]; then
        unreleased+=("$chart $after")
    else
        echo "$chart: $before -> $after"
    fi
done

if [ "${#unreleased[@]}" -gt 0 ]; then
    for entry in "${unreleased[@]}"; do
        echo "::error::Chart ${entry% *} changed but its version is still ${entry#* }: the change would not be released. Bump the version in a new pull request."
    done
    exit 1
fi
echo "Every changed chart has a new version"
