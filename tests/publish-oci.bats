#!/usr/bin/env bats
# Tests for scripts/publish-oci.sh, with a fake helm whose registry holds a-1.0.0.

load helpers

SCRIPT="$BATS_TEST_DIRNAME/../scripts/publish-oci.sh"

setup() {
    mkdir -p "$BATS_TEST_TMPDIR/repo" && cd "$BATS_TEST_TMPDIR/repo"
    chart a 1.0.0
    chart b 2.0.0
    fake_command helm
    cat > "$BATS_TEST_TMPDIR/helm.sh" <<'EOF'
case "$1" in
    show) [ "$3 $5" = "oci://registry.example.org/charts/a 1.0.0" ] || exit 1 ;;
esac
EOF
    export REGISTRY=oci://registry.example.org/charts
}

@test "only the versions missing in the registry are pushed" {
    run "$SCRIPT"
    [ "$status" -eq 0 ]
    [[ "$output" == *"a 1.0.0 is already in registry.example.org/charts"* ]]
    ! grep -q "push .*/a-1.0.0.tgz" "$BATS_TEST_TMPDIR/helm.log"
    grep -q "^dependency build charts/b$" "$BATS_TEST_TMPDIR/helm.log"
    grep -q "^push .*/b-2.0.0.tgz oci://registry.example.org/charts$" "$BATS_TEST_TMPDIR/helm.log"
}

@test "CHARTS limits the charts pushed" {
    CHARTS=a run "$SCRIPT"
    [ "$status" -eq 0 ]
    ! grep -q "charts/b" "$BATS_TEST_TMPDIR/helm.log"
}
