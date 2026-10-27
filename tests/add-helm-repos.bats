#!/usr/bin/env bats
# Tests for scripts/add-helm-repos.sh, with a fake helm.

load helpers

SCRIPT="$BATS_TEST_DIRNAME/../scripts/add-helm-repos.sh"

setup() {
    mkdir -p "$BATS_TEST_TMPDIR/repo" && cd "$BATS_TEST_TMPDIR/repo"
    fake_command helm
}

@test "each http(s) repository is added once, OCI and local ones are skipped" {
    chart a 1.0.0 x 1.0.0 https://charts.example.org/ y 2.0.0 oci://quay.io/example z 1.0.0 file://../z
    chart b 1.0.0 w 1.0.0 https://charts.example.org v 1.0.0 http://other.example.org/charts
    chart c 1.0.0
    run "$SCRIPT"
    [ "$status" -eq 0 ]
    [ "$(grep -c '^repo add' "$BATS_TEST_TMPDIR/helm.log")" -eq 2 ]
    grep -q "repo add --force-update dependency-1 https://charts.example.org$" "$BATS_TEST_TMPDIR/helm.log"
    grep -q "repo add --force-update dependency-2 http://other.example.org/charts$" "$BATS_TEST_TMPDIR/helm.log"
    grep -qx "repo update" "$BATS_TEST_TMPDIR/helm.log"
}

@test "without dependencies nothing is added" {
    chart a 1.0.0
    run "$SCRIPT"
    [ "$status" -eq 0 ]
    [ ! -s "$BATS_TEST_TMPDIR/helm.log" ]
}
