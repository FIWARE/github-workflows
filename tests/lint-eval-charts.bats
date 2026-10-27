#!/usr/bin/env bats
# Tests for scripts/lint-charts.sh and scripts/eval-charts.sh, with the real helm and kubeconform:
# skipped when they are not installed.

load helpers

LINT="$BATS_TEST_DIRNAME/../scripts/lint-charts.sh"
EVAL="$BATS_TEST_DIRNAME/../scripts/eval-charts.sh"

setup() {
    command -v helm >/dev/null || skip "helm is not installed"
    command -v kubeconform >/dev/null || skip "kubeconform is not installed"
    mkdir -p "$BATS_TEST_TMPDIR/repo" && cd "$BATS_TEST_TMPDIR/repo"
    chart good 1.0.0
    configmap good '{{ .Values.x }}'
    echo "# charts" > charts/README.md
}

# configmap <chart> <data value> [<extra template>]
configmap() {
    cat > "charts/$1/templates/configmap.yaml" <<EOF
apiVersion: v1
kind: ConfigMap
metadata:
  name: {{ .Release.Name }}
data:
  x: "$2"
EOF
}

@test "valid charts pass, and directories without a Chart.yaml are ignored" {
    run "$LINT"
    [ "$status" -eq 0 ]
    run "$EVAL"
    [ "$status" -eq 0 ]
    [[ "$output" == *"Chart evaluation successful"* ]]
}

@test "a lint error fails, after every chart has been linted" {
    chart broken 1.0.0
    echo '{{ .Values.x ' > charts/broken/templates/bad.yaml
    chart zlast 1.0.0
    run "$LINT"
    [ "$status" -eq 1 ]
    [[ "$output" == *"charts/zlast"* ]]
}

@test "a resource that does not match its schema fails the validation" {
    chart invalid 1.0.0
    cat > charts/invalid/templates/deployment.yaml <<'EOF'
apiVersion: apps/v1
kind: Deployment
metadata:
  name: invalid
spec:
  replicas: "two"
EOF
    run "$EVAL"
    [ "$status" -eq 1 ]
}

@test "the ci values are rendered and validated too" {
    mkdir -p charts/good/ci
    cat > charts/good/templates/extra.yaml <<'EOF'
{{- if .Values.extra }}
apiVersion: apps/v1
kind: Deployment
metadata:
  name: extra
spec:
  replicas: {{ .Values.extra.replicas }}
{{- end }}
EOF
    echo 'extra: {replicas: "many"}' > charts/good/ci/extra-values.yaml
    run "$EVAL"
    [ "$status" -eq 1 ]
    [[ "$output" == *"Evaluating charts/good with extra-values.yaml"* ]]
}
