#!/usr/bin/env bash
# Lints every Helm chart under CHARTS_DIR: the directories that hold a Chart.yaml. Every chart is
# linted before the result is reported, so one failure does not hide the state of the others.
# Dependencies are not fetched: a missing charts/ directory is a lint warning, not an error.
#
# Environment:
#   CHARTS_DIR  directory that holds one directory per chart (default: charts)
#   HELM        helm binary (default: helm)

set -uo pipefail

CHARTS_DIR="${CHARTS_DIR:-charts}"
HELM="${HELM:-helm}"

status=0
for chart_file in "$CHARTS_DIR"/*/Chart.yaml; do
    [ -f "$chart_file" ] || continue
    if ! "$HELM" lint "$(dirname "$chart_file")"; then
        status=1
    fi
done
exit $status
