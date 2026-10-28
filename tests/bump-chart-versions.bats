#!/usr/bin/env bats
# Tests for scripts/bump-chart-versions.sh against a throwaway repository: a bare "upstream" with the
# base branch, and a clone with the pull request branch.

SCRIPT="$BATS_TEST_DIRNAME/../scripts/bump-chart-versions.sh"

setup() {
    export GIT_AUTHOR_NAME=test GIT_AUTHOR_EMAIL=test@example.org
    export GIT_COMMITTER_NAME=test GIT_COMMITTER_EMAIL=test@example.org
    export GITHUB_OUTPUT="$BATS_TEST_TMPDIR/output"
    : > "$GITHUB_OUTPUT"

    git init --quiet --bare --initial-branch=main "$BATS_TEST_TMPDIR/upstream.git"
    git clone --quiet "$BATS_TEST_TMPDIR/upstream.git" "$BATS_TEST_TMPDIR/repo" 2>/dev/null
    cd "$BATS_TEST_TMPDIR/repo"
    git checkout --quiet -b main
    chart a 1.2.3
    chart b 0.4.0-rc1
    echo "# charts" > charts/README.md
    echo "docs" > README.md
    git add . && git commit --quiet -m base
    git push --quiet origin main
    git checkout --quiet -b feature

    export BASE_REF=main
}

chart() {
    mkdir -p "charts/$1/templates"
    printf 'apiVersion: v2\nname: %s\nversion: %s\n' "$1" "$2" > "charts/$1/Chart.yaml"
    echo "x: 1" > "charts/$1/values.yaml"
}

change() {
    echo "$2" >> "$1"
    git add . && git commit --quiet -m "change $1"
}

version() {
    yq e '.version' "charts/$1/Chart.yaml"
}

@test "patch, minor and major bump from the base version" {
    change charts/a/values.yaml "y: 2"
    for bump in patch minor major; do
        git reset --quiet --hard "$(git rev-parse HEAD)"
        BUMP=$bump run "$SCRIPT"
        [ "$status" -eq 0 ]
        case $bump in
            patch) [ "$(version a)" = 1.2.4 ] ;;
            minor) [ "$(version a)" = 1.3.0 ] ;;
            major) [ "$(version a)" = 2.0.0 ] ;;
        esac
        git reset --quiet --hard HEAD~1
    done
}

@test "commits only the changed chart and reports it" {
    change charts/a/templates/x.yaml "kind: ConfigMap"
    BUMP=minor run "$SCRIPT"
    [ "$status" -eq 0 ]
    [ "$(version a)" = 1.3.0 ]
    [ "$(version b)" = 0.4.0-rc1 ]
    [ "$(git log -1 --format=%s)" = "Update helm chart versions" ]
    [ "$(git log -1 --format=%an)" = "github-actions[bot]" ]
    [ "$(git show --name-only --format= HEAD)" = "charts/a/Chart.yaml" ]
    grep -qx "committed=true" "$GITHUB_OUTPUT"
    grep -qx "charts=a" "$GITHUB_OUTPUT"
}

@test "running it again changes nothing" {
    change charts/a/values.yaml "y: 2"
    BUMP=patch run "$SCRIPT"
    head=$(git rev-parse HEAD)
    : > "$GITHUB_OUTPUT"
    BUMP=patch run "$SCRIPT"
    [ "$status" -eq 0 ]
    [ "$(git rev-parse HEAD)" = "$head" ]
    [ "$(version a)" = 1.2.4 ]
    grep -qx "committed=false" "$GITHUB_OUTPUT"
    grep -qx "changed=a" "$GITHUB_OUTPUT"
}

@test "a version set by hand to the expected one is kept" {
    change charts/a/values.yaml "y: 2"
    sed -i.bak 's/^version: .*/version: 1.3.0/' charts/a/Chart.yaml && rm charts/a/Chart.yaml.bak
    git commit --quiet -am "release 1.3.0"
    head=$(git rev-parse HEAD)
    BUMP=minor run "$SCRIPT"
    [ "$status" -eq 0 ]
    [ "$(git rev-parse HEAD)" = "$head" ]
}

@test "a version bumped twice on the branch is corrected" {
    change charts/a/values.yaml "y: 2"
    sed -i.bak 's/^version: .*/version: 1.4.0/' charts/a/Chart.yaml && rm charts/a/Chart.yaml.bak
    git commit --quiet -am "bumped twice"
    BUMP=minor run "$SCRIPT"
    [ "$status" -eq 0 ]
    [ "$(version a)" = 1.3.0 ]
}

@test "the pre-release suffix of the base version is dropped" {
    change charts/b/values.yaml "y: 2"
    BUMP=patch run "$SCRIPT"
    [ "$status" -eq 0 ]
    [ "$(version b)" = 0.4.1 ]
}

@test "several charts are bumped in one commit" {
    change charts/a/values.yaml "y: 2"
    change charts/b/values.yaml "y: 2"
    BUMP=patch run "$SCRIPT"
    [ "$status" -eq 0 ]
    [ "$(version a)" = 1.2.4 ]
    [ "$(version b)" = 0.4.1 ]
    [ "$(git log --format=%s HEAD~1..HEAD)" = "Update helm chart versions" ]
    grep -qx "charts=a b" "$GITHUB_OUTPUT"
}

@test "changes outside the charts bump nothing" {
    change README.md "more"
    change charts/README.md "more"
    head=$(git rev-parse HEAD)
    BUMP=major run "$SCRIPT"
    [ "$status" -eq 0 ]
    [ "$(git rev-parse HEAD)" = "$head" ]
    grep -qx "committed=false" "$GITHUB_OUTPUT"
}

@test "a new chart keeps its version" {
    chart c 0.1.0
    git add . && git commit --quiet -m "new chart"
    BUMP=minor run "$SCRIPT"
    [ "$status" -eq 0 ]
    [ "$(version c)" = 0.1.0 ]
    [[ "$output" == *"c is not on main yet"* ]]
}

@test "the base version is the current one of the base branch" {
    change charts/a/values.yaml "y: 2"
    # the base branch moves on after the pull request was opened
    git checkout --quiet main
    sed -i.bak 's/^version: .*/version: 1.5.0/' charts/a/Chart.yaml && rm charts/a/Chart.yaml.bak
    git commit --quiet -am "release 1.5.0" && git push --quiet origin main
    git checkout --quiet feature
    BUMP=patch run "$SCRIPT"
    [ "$status" -eq 0 ]
    [ "$(version a)" = 1.5.1 ]
}

@test "a custom charts directory and exclusions" {
    mkdir -p helm && git mv charts/a helm/a && git commit --quiet -m move && git push --quiet origin feature:main --force
    change helm/a/values.yaml "y: 2"
    change helm/NOTES.md "notes"
    CHARTS_DIR=helm EXCLUDE="helm/a/values.yaml" BUMP=patch run "$SCRIPT"
    [ "$status" -eq 0 ]
    grep -qx "committed=false" "$GITHUB_OUTPUT"
}

@test "an unknown bump fails" {
    BUMP=huge run "$SCRIPT"
    [ "$status" -ne 0 ]
    [[ "$output" == *"Unknown bump 'huge'"* ]]
}
