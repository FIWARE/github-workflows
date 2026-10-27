#!/usr/bin/env bash
# Adds the Helm repositories that the charts' dependencies come from, so that their dependencies
# can be built: every http(s) `repository` of every Chart.yaml under CHARTS_DIR, once each.
# OCI registries (oci://) need no repository, and local dependencies (file://) none either.
#
# Environment:
#   CHARTS_DIR  directory that holds one directory per chart (default: charts)
#   HELM        helm binary (default: helm)
#
# Requires yq (mikefarah, v4).

set -euo pipefail

CHARTS_DIR="${CHARTS_DIR:-charts}"
HELM="${HELM:-helm}"

declare -A seen=()
index=0
for chart_file in "$CHARTS_DIR"/*/Chart.yaml; do
    [ -f "$chart_file" ] || continue
    while IFS= read -r url; do
        case "$url" in
            http://*|https://*) ;;
            *) continue ;;
        esac
        url="${url%/}"
        [ -z "${seen[$url]:-}" ] || continue
        seen[$url]=1
        index=$((index + 1))
        "$HELM" repo add --force-update "dependency-$index" "$url"
    done < <(yq e '.dependencies[].repository // ""' "$chart_file")
done

if [ "$index" -gt 0 ]; then
    "$HELM" repo update
else
    echo "No dependency repositories to add"
fi
