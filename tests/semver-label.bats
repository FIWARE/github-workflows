#!/usr/bin/env bats
# Tests for scripts/semver-label.sh, with a fake gh. $PR_LABELS are the labels of the pull request,
# and $MERGED_PR the merged pull request a pushed commit comes from (empty for none). The first
# $API_FAILURES calls fail the way gh does when GitHub answers with an error page.

load helpers

SCRIPT="$BATS_TEST_DIRNAME/../scripts/semver-label.sh"

setup() {
    mkdir -p "$BATS_TEST_TMPDIR/repo" && cd "$BATS_TEST_TMPDIR/repo"
    fake_command gh
    cat > "$BATS_TEST_TMPDIR/gh.sh" <<'EOF'
calls=$(($(cat "$BATS_TEST_TMPDIR/gh.calls" 2>/dev/null || echo 0) + 1))
echo "$calls" > "$BATS_TEST_TMPDIR/gh.calls"
if [ "$calls" -le "${API_FAILURES:-0}" ]; then
    echo "invalid character '<' looking for beginning of value" >&2
    exit 1
fi
case "$2" in
    repos/owner/repo/pulls/*) echo "${PR_LABELS:-[]}" ;;
    repos/owner/repo/commits/*/pulls) echo "${MERGED_PR:-}" ;;
esac
EOF
    export REPOSITORY=owner/repo GITHUB_OUTPUT="$BATS_TEST_TMPDIR/output" RETRY_DELAY=0
    : > "$GITHUB_OUTPUT"
}

@test "a pull request takes the label it has now" {
    EVENT=pull_request PR=7 PR_LABELS='["documentation","minor"]' run "$SCRIPT"
    [ "$status" -eq 0 ]
    [ "${lines[-1]}" = minor ]
    grep -qx "bump=minor" "$GITHUB_OUTPUT"
    grep -q "api repos/owner/repo/pulls/7" "$BATS_TEST_TMPDIR/gh.log"
}

@test "a pull request without a semver label fails, saying the label is missing" {
    EVENT=pull_request PR=7 PR_LABELS='["documentation"]' run "$SCRIPT"
    [ "$status" -eq 1 ]
    [[ "$output" == *"needs exactly one of the labels major, minor or patch (found: none)"* ]]
    grep -qx "label-missing=true" "$GITHUB_OUTPUT"
}

@test "a pull request with two semver labels fails" {
    EVENT=pull_request PR=7 PR_LABELS='["minor","patch"]' run "$SCRIPT"
    [ "$status" -eq 1 ]
    [[ "$output" == *"(found: minor patch)"* ]]
}

@test "a default bump does not apply to pull requests" {
    EVENT=pull_request PR=7 PR_LABELS='[]' DEFAULT_BUMP=patch run "$SCRIPT"
    [ "$status" -eq 1 ]
}

@test "a push takes the label of the merged pull request" {
    EVENT=push SHA=abc MERGED_PR='{"number":9,"labels":["major"]}' run "$SCRIPT"
    [ "$status" -eq 0 ]
    [ "${lines[-1]}" = major ]
    [[ "$output" == *"Releasing pull request #9"* ]]
}

@test "a push that no merged pull request carries fails" {
    EVENT=push SHA=abc run "$SCRIPT"
    [ "$status" -eq 1 ]
    [[ "$output" == *"No merged pull request contains abc"* ]]
}

@test "a push that no merged pull request carries takes the default bump" {
    EVENT=push SHA=abc DEFAULT_BUMP=patch run "$SCRIPT"
    [ "$status" -eq 0 ]
    [ "${lines[-1]}" = patch ]
    grep -qx "bump=patch" "$GITHUB_OUTPUT"
}

@test "a push from a pull request without a semver label takes the default bump" {
    EVENT=push SHA=abc DEFAULT_BUMP=patch MERGED_PR='{"number":9,"labels":[]}' run "$SCRIPT"
    [ "$status" -eq 0 ]
    [ "${lines[-1]}" = patch ]
}

@test "the label of the pull request wins over the default bump" {
    EVENT=push SHA=abc DEFAULT_BUMP=patch MERGED_PR='{"number":9,"labels":["minor"]}' run "$SCRIPT"
    [ "$status" -eq 0 ]
    [ "${lines[-1]}" = minor ]
}

@test "an invalid default bump fails" {
    EVENT=push SHA=abc DEFAULT_BUMP=huge run "$SCRIPT"
    [ "$status" -eq 1 ]
}

@test "a failed API call is retried" {
    EVENT=pull_request PR=7 PR_LABELS='["patch"]' API_FAILURES=2 run "$SCRIPT"
    [ "$status" -eq 0 ]
    [ "${lines[-1]}" = patch ]
    [ "$(grep -c "api repos/owner/repo/pulls/7" "$BATS_TEST_TMPDIR/gh.log")" -eq 3 ]
    [[ "$output" == *"retrying"* ]]
}

@test "an API that keeps failing fails without blaming the label" {
    EVENT=pull_request PR=7 PR_LABELS='["patch"]' API_FAILURES=3 run "$SCRIPT"
    [ "$status" -eq 2 ]
    [[ "$output" == *"The GitHub API call failed 3 times"* ]]
    ! grep -q "label-missing" "$GITHUB_OUTPUT"
}

@test "the merged pull request of a push is read with retries too" {
    EVENT=push SHA=abc MERGED_PR='{"number":9,"labels":["minor"]}' API_FAILURES=1 run "$SCRIPT"
    [ "$status" -eq 0 ]
    [ "${lines[-1]}" = minor ]
}

@test "a push that no merged pull request carries says the label is missing" {
    EVENT=push SHA=abc run "$SCRIPT"
    [ "$status" -eq 1 ]
    grep -qx "label-missing=true" "$GITHUB_OUTPUT"
}
