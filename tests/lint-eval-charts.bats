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

# crd <chart> [<extra string property>]
# gives the chart a CRD for widgets.example.test, whose spec takes a "size" integer and, when
# asked for, one more string property. The group is not in the CRDs catalog, so a widget can only
# validate against the CRD the chart itself ships.
crd() {
    local extra=""
    [ -z "${2:-}" ] || extra=$(printf '\n                %s:\n                  type: string' "$2")
    mkdir -p "charts/$1/crds"
    cat > "charts/$1/crds/widget.yaml" <<EOF
apiVersion: apiextensions.k8s.io/v1
kind: CustomResourceDefinition
metadata:
  name: widgets.example.test
spec:
  group: example.test
  names:
    kind: Widget
    plural: widgets
  scope: Namespaced
  versions:
    - name: v1
      served: true
      storage: true
      schema:
        openAPIV3Schema:
          type: object
          properties:
            spec:
              type: object
              properties:
                size:
                  type: integer$extra
EOF
}

# widget <chart> <spec body>
widget() {
    cat > "charts/$1/templates/widget.yaml" <<EOF
apiVersion: example.test/v1
kind: Widget
metadata:
  name: widget
spec:
$2
EOF
}

@test "a custom resource is validated against the CRD its own chart ships" {
    crd good
    widget good "  size: 3"
    run "$EVAL"
    [ "$status" -eq 0 ]
    [[ "$output" == *"Chart evaluation successful"* ]]
}

@test "a custom resource that the chart's own CRD rejects fails" {
    crd good
    widget good "  size: big"
    run "$EVAL"
    [ "$status" -eq 1 ]
}

@test "a property the chart's CRD adds is accepted, where the catalog alone would reject it" {
    crd good colour
    widget good "  size: 3
  colour: red"
    run "$EVAL"
    [ "$status" -eq 0 ]
}

@test "a crds directory that is not a chart's own is ignored" {
    # opentelemetry-operator keeps Helm templates in conf/crds; they are not parseable YAML and
    # must not be read as CRDs
    mkdir -p charts/good/conf/crds
    echo '{{- if .Values.x }}' > charts/good/conf/crds/templated.yaml
    run "$EVAL"
    [ "$status" -eq 0 ]
    [[ "$output" != *"bad file"* ]]
}

@test "the CRDs a dependency ships are read from the archive helm builds" {
    chart dep 1.0.0
    crd dep
    # the widget is in the chart that depends on dep, so its schema can only come from the
    # dep-1.0.0.tgz that helm dependency build puts in charts/user/charts
    chart user 1.0.0 dep 1.0.0 "file://../dep"
    widget user "  size: 3"
    run "$EVAL"
    [ "$status" -eq 0 ]
    [[ "$output" == *"Chart evaluation successful"* ]]
}
