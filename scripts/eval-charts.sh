#!/usr/bin/env bash
# Renders every Helm chart under CHARTS_DIR and validates the result with kubeconform: with the
# default values, and with each <chart>/ci/*-values.yaml, which can turn on what the defaults
# leave off. Custom resources are validated against the CRDs catalog
# (https://github.com/datreeio/CRDs-catalog); with the ci values, those that are not in it are
# skipped, every other resource is still validated strictly. Every chart is evaluated before the
# result is reported.
#
# Environment:
#   CHARTS_DIR   directory that holds one directory per chart (default: charts)
#   HELM         helm binary (default: helm)
#   KUBECONFORM  kubeconform binary (default: kubeconform)
#
# Run add-helm-repos.sh first for charts with dependencies.

set -uo pipefail

CHARTS_DIR="${CHARTS_DIR:-charts}"
HELM="${HELM:-helm}"
KUBECONFORM="${KUBECONFORM:-kubeconform}"
SCHEMAS=(-schema-location default
         -schema-location 'https://raw.githubusercontent.com/datreeio/CRDs-catalog/main/{{.Group}}/{{.ResourceKind}}_{{.ResourceAPIVersion}}.json')

status=0
for chart_file in "$CHARTS_DIR"/*/Chart.yaml; do
    [ -f "$chart_file" ] || continue
    chart=$(dirname "$chart_file")

    echo "Evaluating $chart"
    if ! "$HELM" dependency build "$chart"; then
        status=1
        continue
    fi
    if ! "$HELM" template "$chart" | "$KUBECONFORM" -strict -summary "${SCHEMAS[@]}"; then
        status=1
    fi

    for values in "$chart"/ci/*-values.yaml; do
        [ -f "$values" ] || continue
        echo "Evaluating $chart with $(basename "$values")"
        if ! "$HELM" template "$chart" -f "$values" | "$KUBECONFORM" -strict -summary -ignore-missing-schemas "${SCHEMAS[@]}"; then
            status=1
        fi
    done
done

if [ "$status" -eq 0 ]; then
    echo "Chart evaluation successful"
fi
exit $status
