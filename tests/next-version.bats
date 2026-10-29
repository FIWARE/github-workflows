#!/usr/bin/env bats
# Tests for scripts/next-version.sh against a throwaway repository with release tags.

SCRIPT="$BATS_TEST_DIRNAME/../scripts/next-version.sh"

setup() {
    export GIT_AUTHOR_NAME=test GIT_AUTHOR_EMAIL=test@example.org
    export GIT_COMMITTER_NAME=test GIT_COMMITTER_EMAIL=test@example.org
    git init --quiet "$BATS_TEST_TMPDIR/repo"
    cd "$BATS_TEST_TMPDIR/repo"
    git commit --quiet --allow-empty -m initial
}

@test "without tags the first release is the bump of 0.0.0" {
    BUMP=major run "$SCRIPT"
    [ "$output" = 1.0.0 ]
    BUMP=minor run "$SCRIPT"
    [ "$output" = 0.1.0 ]
}

@test "patch, minor and major bump the highest release" {
    git tag v1.2.3
    BUMP=patch run "$SCRIPT"
    [ "$output" = 1.2.4 ]
    BUMP=minor run "$SCRIPT"
    [ "$output" = 1.3.0 ]
    BUMP=major run "$SCRIPT"
    [ "$output" = 2.0.0 ]
}

@test "versions are compared as numbers, not as text" {
    git tag v1.9.0
    git tag v1.10.0
    git tag v1.2.15
    BUMP=patch run "$SCRIPT"
    [ "$output" = 1.10.1 ]
}

@test "major tags, pre-releases and other tags are ignored" {
    git tag v1.0.2
    git tag v1
    git tag v2
    git tag v1.1.0-rc1
    git tag latest
    BUMP=patch run "$SCRIPT"
    [ "$output" = 1.0.3 ]
}

@test "the highest release counts, also after a new major" {
    git tag v1.4.0
    git tag v2.0.0
    git tag v1.4.1
    BUMP=minor run "$SCRIPT"
    [ "$output" = 2.1.0 ]
}

@test "an unknown bump fails" {
    BUMP=huge run "$SCRIPT"
    [ "$status" -ne 0 ]
}

@test "TAG_PREFIX selects the release tags" {
    git tag v9.0.0
    git tag release-1.2.0
    TAG_PREFIX=release- BUMP=patch run "$SCRIPT"
    [ "$output" = 1.2.1 ]
}

@test "an empty TAG_PREFIX reads tags without a prefix and ignores pre-releases" {
    git tag v9.0.0
    git tag 1.8.4
    git tag 1.8.5-PRE-34
    git tag 1.10.0
    TAG_PREFIX= BUMP=patch run "$SCRIPT"
    [ "$output" = 1.10.1 ]
}
