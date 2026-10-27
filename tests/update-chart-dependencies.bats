#!/usr/bin/env bats
# Tests for scripts/update-chart-dependencies.sh: a bare upstream repository, a Helm repository
# index on disk (file://), and fake gh and crane.

load helpers

SCRIPT="$BATS_TEST_DIRNAME/../scripts/update-chart-dependencies.sh"

setup() {
    git_identity
    export HELM_REPO="$BATS_TEST_TMPDIR/helm-repo"
    mkdir -p "$HELM_REPO"
    cat > "$HELM_REPO/index.yaml" <<'EOF'
apiVersion: v1
entries:
  x:
    - version: 1.10.0
    - version: 1.9.0
    - version: 2.0.0-rc1
  y:
    - version: 0.3.0
EOF

    git init --quiet --bare --initial-branch=main "$BATS_TEST_TMPDIR/upstream.git"
    git clone --quiet "$BATS_TEST_TMPDIR/upstream.git" "$BATS_TEST_TMPDIR/repo" 2>/dev/null
    cd "$BATS_TEST_TMPDIR/repo"
    git checkout --quiet -b main
    chart app 1.2.3 x 1.9.0 "file://$HELM_REPO" y 0.3.0 "file://$HELM_REPO" z 0.1.0 oci://registry.example.org/charts
    git add . && git commit --quiet -m base && git push --quiet origin main

    fake_command gh
    fake_command crane
    echo 'echo 0.1.0; echo 0.2.0; echo latest' > "$BATS_TEST_TMPDIR/crane.sh"
    export BASE_BRANCH=main REVIEWERS=someone
}

remote_version() {
    git show "origin/$1:charts/app/Chart.yaml" | yq e "$2" -
}

@test "a pull request per outdated dependency, with the chart version bumped" {
    run "$SCRIPT"
    [ "$status" -eq 0 ]
    git fetch --quiet origin
    # x: 1.9.0 -> 1.10.0, the release candidate is ignored and 1.10.0 is higher than 1.9.0
    [ "$(remote_version bump/app-x-1.10.0 '.dependencies[0].version')" = 1.10.0 ]
    [ "$(remote_version bump/app-x-1.10.0 '.version')" = 1.2.4 ]
    # z, from the OCI registry: 0.1.0 -> 0.2.0, and the chart version from main again
    [ "$(remote_version bump/app-z-0.2.0 '.dependencies[2].version')" = 0.2.0 ]
    [ "$(remote_version bump/app-z-0.2.0 '.dependencies[0].version')" = 1.9.0 ]
    [ "$(remote_version bump/app-z-0.2.0 '.version')" = 1.2.4 ]
    # y is up to date
    ! git rev-parse --quiet --verify origin/bump/app-y-0.3.0
    grep -q "pr create --base main --head bump/app-x-1.10.0 --title chore(deps): bump x to 1.10.0 in app --label patch" "$BATS_TEST_TMPDIR/gh.log"
    grep -q -- "--reviewer someone" "$BATS_TEST_TMPDIR/gh.log"
    [ "$(git log -1 --format=%s origin/bump/app-x-1.10.0)" = "Update helm chart versions" ]
    [ "$(git log -1 --format=%s origin/bump/app-x-1.10.0~1)" = "chore(deps): bump x to 1.10.0 in app" ]
    [ "$(git rev-parse origin/main)" = "$(git rev-parse main)" ]
}

@test "the label sets the bump of the chart version" {
    LABEL=minor run "$SCRIPT"
    [ "$status" -eq 0 ]
    git fetch --quiet origin
    [ "$(remote_version bump/app-x-1.10.0 '.version')" = 1.3.0 ]
    grep -q -- "--label minor" "$BATS_TEST_TMPDIR/gh.log"
}

@test "an open pull request for a dependency, of any version, holds it back" {
    echo 'if [ "$1 $2" = "pr list" ]; then echo bump/app-x-1.9.5; fi' > "$BATS_TEST_TMPDIR/gh.sh"
    run "$SCRIPT"
    [ "$status" -eq 0 ]
    [[ "$output" == *"app/x: 1.9.0 -> 1.10.0, but a pull request for it is already open"* ]]
    ! grep -q "head bump/app-x-" "$BATS_TEST_TMPDIR/gh.log"
    grep -q "head bump/app-z-0.2.0" "$BATS_TEST_TMPDIR/gh.log"
}

@test "an existing branch is not pushed again" {
    git push --quiet origin main:refs/heads/bump/app-x-1.10.0
    run "$SCRIPT"
    [ "$status" -eq 0 ]
    [[ "$output" == *"branch bump/app-x-1.10.0 already exists"* ]]
}

@test "a dry run changes nothing" {
    DRY_RUN=true run "$SCRIPT"
    [ "$status" -eq 0 ]
    [[ "$output" == *"app/x: 1.9.0 -> 1.10.0"* ]]
    ! grep -q "pr create" "$BATS_TEST_TMPDIR/gh.log"
    [ -z "$(git ls-remote --heads origin 'bump/*')" ]
}
