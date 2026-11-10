#!/usr/bin/env bats
# Tests for scripts/github-release.sh, with a fake gh. $EXISTING_RELEASE and $EXISTING_TAG name the
# release and the tag the fake repository already has, and $TAGS lists all its tags.

load helpers

SCRIPT="$BATS_TEST_DIRNAME/../scripts/github-release.sh"

setup() {
    mkdir -p "$BATS_TEST_TMPDIR/repo" && cd "$BATS_TEST_TMPDIR/repo"
    fake_command gh
    cat > "$BATS_TEST_TMPDIR/gh.sh" <<'EOF'
case "$1 $2" in
    "api --paginate") printf '%s\n' ${TAGS:-} ;;
    "release view") [ "$3" = "${EXISTING_RELEASE:-}" ] || exit 1 ;;
    "api repos/owner/repo/git/ref/tags/"*) [ "${2##*/}" = "${EXISTING_TAG:-}" ] || exit 1 ;;
esac
EOF
    export VERSION=1.2.3 TARGET=abc123 REPOSITORY=owner/repo
}

@test "a release is created on the target, with generated notes" {
    run "$SCRIPT"
    [ "$status" -eq 0 ]
    grep -qx "release create 1.2.3 --repo owner/repo --target abc123 --title 1.2.3 --generate-notes" "$BATS_TEST_TMPDIR/gh.log"
    ! grep -q -- "--prerelease" "$BATS_TEST_TMPDIR/gh.log"
    ! grep -q "release delete" "$BATS_TEST_TMPDIR/gh.log"
}

@test "a pre-release is marked as such and takes the title" {
    VERSION=1.2.3-PRE-7 PRERELEASE=true TITLE="Pre-release 7" run "$SCRIPT"
    [ "$status" -eq 0 ]
    grep -q "release create 1.2.3-PRE-7 .* --title Pre-release 7 --generate-notes --prerelease" "$BATS_TEST_TMPDIR/gh.log"
}

@test "an existing pre-release and its tag are replaced" {
    EXISTING_RELEASE=1.2.3-PRE-7 EXISTING_TAG=1.2.3-PRE-7 VERSION=1.2.3-PRE-7 PRERELEASE=true run "$SCRIPT"
    [ "$status" -eq 0 ]
    [[ "$output" == *"Replacing the pre-release 1.2.3-PRE-7"* ]]
    grep -qx "release delete 1.2.3-PRE-7 --repo owner/repo --yes" "$BATS_TEST_TMPDIR/gh.log"
    grep -qx "api -X DELETE repos/owner/repo/git/refs/tags/1.2.3-PRE-7" "$BATS_TEST_TMPDIR/gh.log"
    grep -q "release create 1.2.3-PRE-7" "$BATS_TEST_TMPDIR/gh.log"
}

@test "a pre-release tag left without its release is replaced too" {
    EXISTING_TAG=1.2.3-PRE-7 VERSION=1.2.3-PRE-7 PRERELEASE=true run "$SCRIPT"
    [ "$status" -eq 0 ]
    ! grep -q "release delete" "$BATS_TEST_TMPDIR/gh.log"
    grep -q "api -X DELETE repos/owner/repo/git/refs/tags/1.2.3-PRE-7" "$BATS_TEST_TMPDIR/gh.log"
}

@test "an existing release is never replaced" {
    EXISTING_RELEASE=1.2.3 EXISTING_TAG=1.2.3 run "$SCRIPT"
    [ "$status" -eq 1 ]
    [[ "$output" == *"1.2.3 already exists"* ]]
    ! grep -q "release delete\|release create\|DELETE" "$BATS_TEST_TMPDIR/gh.log"
}

@test "an existing tag without a release is not replaced by a release" {
    EXISTING_TAG=1.2.3 run "$SCRIPT"
    [ "$status" -eq 1 ]
    ! grep -q "release create" "$BATS_TEST_TMPDIR/gh.log"
}

@test "the files to attach are expanded from their globs" {
    touch LICENSE && mkdir release-assets && touch release-assets/bin-linux-amd64 release-assets/bin-linux-arm64
    FILES=$'LICENSE\nrelease-assets/bin-*' run "$SCRIPT"
    [ "$status" -eq 0 ]
    grep -q "release create 1.2.3 .* --generate-notes LICENSE release-assets/bin-linux-amd64 release-assets/bin-linux-arm64$" "$BATS_TEST_TMPDIR/gh.log"
}

@test "a glob that matches nothing fails before publishing" {
    FILES="missing-*" run "$SCRIPT"
    [ "$status" -eq 1 ]
    [[ "$output" == *"No file matches 'missing-*'"* ]]
    ! grep -q "release create" "$BATS_TEST_TMPDIR/gh.log"
}

@test "an invalid prerelease flag fails" {
    PRERELEASE=yes run "$SCRIPT"
    [ "$status" -eq 1 ]
}

@test "the notes start from the previous release of the same series, not from another series" {
    TAGS="1.0.0 0.9.0 1.0.1-PRE-45 decentralized-iam-2.1.30 1.1.0" VERSION=1.0.1-PRE-45 PRERELEASE=true run "$SCRIPT"
    [ "$status" -eq 0 ]
    [[ "$output" == *"Release notes start from 1.0.0"* ]]
    grep -q "release create 1.0.1-PRE-45 .* --notes-start-tag 1.0.0" "$BATS_TEST_TMPDIR/gh.log"
}

@test "a release takes the previous release as start, numerically" {
    TAGS="11.9.0 11.39.0 11.38.1-PRE-3 11.4.0" VERSION=11.39.1 run "$SCRIPT"
    [ "$status" -eq 0 ]
    grep -q -- "--notes-start-tag 11.39.0$" "$BATS_TEST_TMPDIR/gh.log"
}

@test "a prefixed version only looks at the tags with its prefix" {
    TAGS="v1.1.2 v1 1.5.0 v1.2.0" VERSION=v1.2.1 run "$SCRIPT"
    [ "$status" -eq 0 ]
    grep -q -- "--notes-start-tag v1.2.0$" "$BATS_TEST_TMPDIR/gh.log"
}

@test "without a previous release the notes have no start tag" {
    TAGS="decentralized-iam-2.1.30 1.0.1-PRE-45" VERSION=1.0.0 run "$SCRIPT"
    [ "$status" -eq 0 ]
    ! grep -q -- "--notes-start-tag" "$BATS_TEST_TMPDIR/gh.log"
}

@test "NOTES_START_TAG overrides the previous release, and empty disables it" {
    TAGS="1.0.0" NOTES_START_TAG=0.5.0 VERSION=1.0.1 run "$SCRIPT"
    grep -q -- "--notes-start-tag 0.5.0$" "$BATS_TEST_TMPDIR/gh.log"
    : > "$BATS_TEST_TMPDIR/gh.log"
    TAGS="1.0.0" NOTES_START_TAG="" VERSION=1.0.1 run "$SCRIPT"
    ! grep -q -- "--notes-start-tag" "$BATS_TEST_TMPDIR/gh.log"
}
