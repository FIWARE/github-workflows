# Shared helpers for the bats tests.

# a git identity, for the commits the tests make
git_identity() {
    export GIT_AUTHOR_NAME=test GIT_AUTHOR_EMAIL=test@example.org
    export GIT_COMMITTER_NAME=test GIT_COMMITTER_EMAIL=test@example.org
}

# chart <name> <version> [<dependency name> <dependency version> <repository>]...
# writes charts/<name>/Chart.yaml (and a values.yaml) in the current directory
chart() {
    local name=$1 version=$2
    shift 2
    mkdir -p "charts/$name/templates"
    printf 'apiVersion: v2\nname: %s\nversion: %s\n' "$name" "$version" > "charts/$name/Chart.yaml"
    if [ $# -gt 0 ]; then
        echo "dependencies:" >> "charts/$name/Chart.yaml"
        while [ $# -ge 3 ]; do
            printf '  - name: %s\n    version: %s\n    repository: %s\n' "$1" "$2" "$3" >> "charts/$name/Chart.yaml"
            shift 3
        done
    fi
    echo "x: 1" > "charts/$name/values.yaml"
}

version_of() {
    yq e '.version' "charts/$1/Chart.yaml"
}

# fake_command <name>: a command on PATH that records its arguments in $BATS_TEST_TMPDIR/<name>.log
# and runs $BATS_TEST_TMPDIR/<name>.sh, if it exists, with them
fake_command() {
    mkdir -p "$BATS_TEST_TMPDIR/bin"
    cat > "$BATS_TEST_TMPDIR/bin/$1" <<EOF
#!/usr/bin/env bash
echo "\$*" >> "$BATS_TEST_TMPDIR/$1.log"
if [ -f "$BATS_TEST_TMPDIR/$1.sh" ]; then
    source "$BATS_TEST_TMPDIR/$1.sh"
fi
EOF
    chmod +x "$BATS_TEST_TMPDIR/bin/$1"
    touch "$BATS_TEST_TMPDIR/$1.log"
    export PATH="$BATS_TEST_TMPDIR/bin:$PATH"
}
