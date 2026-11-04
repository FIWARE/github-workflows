#!/usr/bin/env bash
# Renders every Helm chart under CHARTS_DIR and validates the result with kubeconform: with the
# default values, and with each <chart>/ci/*-values.yaml, which can turn on what the defaults
# leave off. Custom resources are validated against the CRDs the chart itself ships - its own
# crds/ and those of its dependencies - and, for the kinds it defines none, against the CRDs
# catalog (https://github.com/datreeio/CRDs-catalog); with the ci values, those that are in
# neither are skipped, every other resource is still validated strictly. Every chart is evaluated
# before the result is reported.
#
# A chart's own CRD comes first because it is the authority for its custom resources: the catalog
# is generated from whichever CRD version it was last refreshed with, so a field that the operator
# the chart deploys accepts today can be rejected by a schema built from an older one.
#
# Environment:
#   CHARTS_DIR   directory that holds one directory per chart (default: charts)
#   HELM         helm binary (default: helm)
#   KUBECONFORM  kubeconform binary (default: kubeconform)
#   YQ           yq binary (mikefarah v4.45.1 or newer - an older one cannot parse the query that
#                reads the CRD versions, and v4.35.2 rejects it outright; default: yq)
#
# Run add-helm-repos.sh first for charts with dependencies.

set -uo pipefail

CHARTS_DIR="${CHARTS_DIR:-charts}"
HELM="${HELM:-helm}"
KUBECONFORM="${KUBECONFORM:-kubeconform}"
YQ="${YQ:-yq}"

# How kubeconform addresses a schema. It renders the kind in lower case, which is the name the
# catalog uses and the name write_crd_schemas writes.
SCHEMA_PATH='{{.Group}}/{{.ResourceKind}}_{{.ResourceAPIVersion}}.json'
CATALOG="https://raw.githubusercontent.com/datreeio/CRDs-catalog/main/$SCHEMA_PATH"

workdir=$(mktemp -d)
trap 'rm -rf "$workdir"' EXIT

# write_crd_schemas <chart> <schema dir> <unpack dir>
# Writes the openAPIV3Schema of every CustomResourceDefinition version the chart ships to
# <schema dir>/<group>/<kind>_<version>.json. A dependency's CRDs are inside the archive that
# helm dependency build leaves in <chart>/charts, so those are unpacked first; the chart's own
# crds/, and a dependency that is already unpacked, are read where they are.
write_crd_schemas() {
    local chart=$1 schema_dir=$2 unpack_dir=$3
    local archive crd entries doc group kind index version

    # one line "<document> <group> <kind> <version index> <version>" per schema to write.
    # shellcheck disable=SC2016 # $crd is a yq variable, not a shell one
    local versions_query='
        select(.kind == "CustomResourceDefinition") |
        [documentIndex, .spec.group, .spec.names.kind] as $crd |
        .spec.versions | to_entries[] |
        select(.value.schema.openAPIV3Schema != null) |
        ($crd + [.key, .value.name]) | join(" ")'

    mkdir -p "$unpack_dir"
    for archive in "$chart"/charts/*.tgz; do
        [ -f "$archive" ] || continue
        tar -xzf "$archive" -C "$unpack_dir" || return 1
    done

    # the query is read into a variable rather than piped in: the exit status of a process
    # substitution is lost, and an unreadable CRD would then leave no schema and silently send
    # kubeconform back to the catalog - the very failure this works around
    while IFS= read -r crd; do
        entries=$("$YQ" e -N "$versions_query" "$crd") || return 1
        while read -r doc group kind index version; do
            [ -n "${version:-}" ] || continue
            mkdir -p "$schema_dir/$group"
            "$YQ" e -N -o=json \
                "select(documentIndex == $doc) | .spec.versions[$index].schema.openAPIV3Schema" \
                "$crd" > "$schema_dir/$group/${kind,,}_$version.json" || return 1
        done <<< "$entries"
    done < <(crd_files "$chart" "$unpack_dir")
}

# crd_files <dir>...
# Prints every CRD file under the given directories: the *.yaml in a crds/ directory that sits
# directly in a chart, which is where Helm reads them from. A crds/ elsewhere in a chart is not
# one - opentelemetry-operator, for instance, keeps Helm templates in conf/crds - and templates
# are not parseable YAML.
crd_files() {
    local crd_dir
    while IFS= read -r crd_dir; do
        [ -f "$(dirname "$crd_dir")/Chart.yaml" ] || continue
        find "$crd_dir" -type f \( -name '*.yaml' -o -name '*.yml' \)
    done < <(find "$@" -type d -name crds 2>/dev/null)
}

status=0
chart_index=0
for chart_file in "$CHARTS_DIR"/*/Chart.yaml; do
    [ -f "$chart_file" ] || continue
    chart=$(dirname "$chart_file")
    chart_index=$((chart_index + 1))

    echo "Evaluating $chart"
    if ! "$HELM" dependency build "$chart"; then
        status=1
        continue
    fi

    # the dependencies are only on disk once they are built, so their CRDs are collected after
    schema_dir="$workdir/schemas/$chart_index"
    if ! write_crd_schemas "$chart" "$schema_dir" "$workdir/unpacked/$chart_index"; then
        echo "Could not read the CRDs of $chart" >&2
        status=1
        continue
    fi
    schemas=(-schema-location default
             -schema-location "$schema_dir/$SCHEMA_PATH"
             -schema-location "$CATALOG")

    if ! "$HELM" template "$chart" | "$KUBECONFORM" -strict -summary "${schemas[@]}"; then
        status=1
    fi

    for values in "$chart"/ci/*-values.yaml; do
        [ -f "$values" ] || continue
        echo "Evaluating $chart with $(basename "$values")"
        if ! "$HELM" template "$chart" -f "$values" | "$KUBECONFORM" -strict -summary -ignore-missing-schemas "${schemas[@]}"; then
            status=1
        fi
    done
done

if [ "$status" -eq 0 ]; then
    echo "Chart evaluation successful"
fi
exit $status
