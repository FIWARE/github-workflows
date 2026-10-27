#!/usr/bin/env bats
# Tests for scripts/check-chart-versions.sh.

load helpers

SCRIPT="$BATS_TEST_DIRNAME/../scripts/check-chart-versions.sh"

setup() {
    git_identity
    git init --quiet "$BATS_TEST_TMPDIR/repo"
    cd "$BATS_TEST_TMPDIR/repo"
    chart a 1.0.0
    chart b 2.0.0
    echo "# charts" > charts/README.md
    git add . && git commit --quiet -m base
    export BEFORE
    BEFORE=$(git rev-parse HEAD)
}

commit() {
    git add -A && git commit --quiet -m "$1"
}

@test "a changed chart with a new version passes" {
    echo "y: 2" >> charts/a/values.yaml
    sed -i.bak 's/^version: .*/version: 1.0.1/' charts/a/Chart.yaml && rm charts/a/Chart.yaml.bak
    commit change
    run "$SCRIPT"
    [ "$status" -eq 0 ]
    [[ "$output" == *"a: 1.0.0 -> 1.0.1"* ]]
}

@test "a changed chart without a new version fails, naming it" {
    echo "y: 2" >> charts/a/values.yaml
    echo "y: 2" >> charts/b/values.yaml
    sed -i.bak 's/^version: .*/version: 2.0.1/' charts/b/Chart.yaml && rm charts/b/Chart.yaml.bak
    commit change
    run "$SCRIPT"
    [ "$status" -eq 1 ]
    [[ "$output" == *"Chart a changed but its version is still 1.0.0"* ]]
    [[ "$output" != *"Chart b changed"* ]]
}

@test "the check covers every commit of the push" {
    echo "y: 2" >> charts/a/values.yaml && commit one
    sed -i.bak 's/^version: .*/version: 1.1.0/' charts/a/Chart.yaml && rm charts/a/Chart.yaml.bak && commit two
    run "$SCRIPT"
    [ "$status" -eq 0 ]
}

@test "changes outside the charts and to the excluded files pass" {
    echo "more" >> charts/README.md
    echo "docs" > README.md
    commit docs
    run "$SCRIPT"
    [ "$status" -eq 0 ]
}

@test "new and removed charts pass" {
    chart c 0.1.0
    git rm --quiet -r charts/b
    commit "new and removed"
    run "$SCRIPT"
    [ "$status" -eq 0 ]
    [[ "$output" == *"c is new, at 0.1.0"* ]]
    [[ "$output" == *"b was removed"* ]]
}

@test "without a previous commit nothing is checked" {
    echo "y: 2" >> charts/a/values.yaml && commit change
    BEFORE=0000000000000000000000000000000000000000 run "$SCRIPT"
    [ "$status" -eq 0 ]
    BEFORE="" run "$SCRIPT"
    [ "$status" -eq 0 ]
}
