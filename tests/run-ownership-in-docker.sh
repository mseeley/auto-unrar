#!/bin/bash
#
# Checks that extracted files end up owned by PUID:PGID rather than by root.
#
#   ./tests/run-ownership-in-docker.sh
#
# Extraction happens inside the container's own filesystem, never in a bind
# mount. Docker Desktop and OrbStack remap ownership on bind mounts from a
# macOS host, so a test that watched a mounted directory would report the host
# user's ids whatever the container did, and would pass even with the
# entrypoint removed.

tests_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_dir="$(dirname "$tests_dir")"
image="auto-unrar-tests"

passed=0
failed=0

pass() { printf '  \033[32mPASS\033[0m %s\n' "$1"; passed=$((passed + 1)); }
fail() { printf '  \033[31mFAIL\033[0m %s\n' "$1"; failed=$((failed + 1)); }

check() {
    local label="$1" expected="$2" actual="$3"
    if [ "$expected" = "$actual" ]; then
        pass "$label"
    else
        fail "$label (expected: $expected, got: $actual)"
    fi
}

if [ ! -d "$tests_dir/fixtures/single-volume" ]; then
    echo "Fixtures missing. Run ./tests/make-fixtures.sh first."
    exit 1
fi

echo "Building $image ..."
docker build -t "$image" "$repo_dir" > /dev/null || exit 1

# Runs one extraction in the container under the given environment and echoes
# "<uid>:<gid> <uid>:<gid>" for the extracted payload and the marker file.
ownership_after_extraction() {
    docker run --rm "$@" \
        -v "$tests_dir/fixtures:/fixtures:ro" \
        "$image" \
        bash -c '
            cp -R /fixtures/single-volume /tmp/data 2>/dev/null
            SOURCE_DIRECTORY=/tmp/data SLEEP_TIME=30 /extract.sh > /tmp/scan.log 2>&1 &
            for _ in $(seq 1 30); do
                [ -f /tmp/data/note.txt ] && [ -f /tmp/data/solo.rar.extracted.marker ] && break
                sleep 1
            done
            printf "%s %s\n" \
                "$(stat -c "%u:%g" /tmp/data/note.txt 2>/dev/null || echo missing)" \
                "$(stat -c "%u:%g" /tmp/data/solo.rar.extracted.marker 2>/dev/null || echo missing)"
        ' 2>/dev/null | tail -1
}

echo
echo "Ownership of extracted files"
echo "----------------------------"

read -r payload marker <<< "$(ownership_after_extraction -e PUID=1234 -e PGID=5678)"
check "PUID/PGID set: payload owned by 1234:5678" "1234:5678" "$payload"
check "PUID/PGID set: marker owned by 1234:5678"  "1234:5678" "$marker"

read -r payload marker <<< "$(ownership_after_extraction -e PUID=1234)"
check "PUID only: gid follows PUID" "1234:1234" "$payload"

# The image published root-owned files before PUID existed, so leaving the
# variables unset has to keep doing that.
read -r payload marker <<< "$(ownership_after_extraction)"
check "neither set: payload stays root owned" "0:0" "$payload"
check "neither set: marker stays root owned"  "0:0" "$marker"

echo
echo "===================================================="
printf 'passed: %d   failed: %d\n' "$passed" "$failed"
echo "===================================================="

[ "$failed" -eq 0 ]
