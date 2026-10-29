#!/usr/bin/env bash
# Pushes the charts to an OCI registry, each version once: a version already in the registry is
# left as it is.
#
# Environment:
#   REGISTRY    registry and path to push to, without oci://, e.g. quay.io/fiware/helm-charts
#               (required; log in to it first)
#   CHARTS      space-separated chart names to push (default: every chart under CHARTS_DIR)
#   CHARTS_DIR  directory that holds one directory per chart (default: charts)
#   HELM        helm binary (default: helm)
#   ATTEMPTS    attempts for each push, as registries answer 502 now and then (default: 3)
#   RETRY_DELAY seconds between the attempts (default: 10)
#
# Requires yq (mikefarah, v4). Run add-helm-repos.sh first for charts with dependencies.

set -euo pipefail

: "${REGISTRY:?REGISTRY must name the OCI registry and path, without oci://}"
CHARTS_DIR="${CHARTS_DIR:-charts}"
HELM="${HELM:-helm}"
ATTEMPTS="${ATTEMPTS:-3}"
RETRY_DELAY="${RETRY_DELAY:-10}"
REGISTRY="${REGISTRY#oci://}"

# retry <command>...: runs the command up to ATTEMPTS times, until it succeeds
retry() {
    local attempt=1
    until "$@"; do
        if [ "$attempt" -ge "$ATTEMPTS" ]; then
            return 1
        fi
        echo "Attempt $attempt of $ATTEMPTS failed, retrying in ${RETRY_DELAY}s" >&2
        sleep "$RETRY_DELAY"
        attempt=$((attempt + 1))
    done
}

if [ -z "${CHARTS:-}" ]; then
    CHARTS=""
    for chart_file in "$CHARTS_DIR"/*/Chart.yaml; do
        [ -f "$chart_file" ] || continue
        CHARTS="$CHARTS $(basename "$(dirname "$chart_file")")"
    done
fi

package_dir=$(mktemp -d)
trap 'rm -rf "$package_dir"' EXIT

for chart in $CHARTS; do
    chart_dir="$CHARTS_DIR/$chart"
    name=$(yq e '.name' "$chart_dir/Chart.yaml")
    version=$(yq e '.version' "$chart_dir/Chart.yaml")
    if "$HELM" show chart "oci://$REGISTRY/$name" --version "$version" >/dev/null 2>&1; then
        echo "$name $version is already in $REGISTRY"
        continue
    fi
    echo "Pushing $name $version to $REGISTRY"
    "$HELM" dependency build "$chart_dir"
    "$HELM" package "$chart_dir" --destination "$package_dir"
    retry "$HELM" push "$package_dir/$name-$version.tgz" "oci://$REGISTRY"
done
