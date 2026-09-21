#!/bin/bash
#
# Tests for extract.sh. Run make-fixtures.sh first to build the archive
# fixtures, which are gitignored.
#
#   ./tests/make-fixtures.sh && ./tests/run-tests.sh
#
# Runs real extractions with deletion enabled and checks that no archive
# volumes are left behind.

# Job control, so each scan runs in its own process group and can be shut down
# along with the sleep it spawns. Killing the group avoids needing pkill, which
# the Debian image does not ship.
set -m

tests_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_dir="$(dirname "$tests_dir")"
fixtures_dir="$tests_dir/fixtures"
work_dir="$tests_dir/work"

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

# Runs one scan of extract.sh over a directory and echoes its output. The script
# loops forever, so this waits for the output to stop growing (meaning the scan
# finished and it has gone to sleep) and then stops it.
run_scan() {
    local source="$1"
    shift
    local log="$work_dir/scan.log"
    rm -f "$log"

    env SOURCE_DIRECTORY="$source" SLEEP_TIME=30 "$@" \
        bash "$repo_dir/extract.sh" > "$log" 2>&1 &
    local pid=$!

    local last=-1 size=0 stable=0
    while kill -0 "$pid" 2>/dev/null; do
        size=$(wc -c < "$log" 2>/dev/null || echo 0)
        if [ "$size" -eq "$last" ]; then
            stable=$((stable + 1))
            [ "$stable" -ge 3 ] && break
        else
            stable=0
        fi
        last=$size
        sleep 1
    done

    # The negative pid targets the process group, taking the sleep with it. The
    # plain kill is the fallback for when job control did not apply.
    kill -- -"$pid" 2>/dev/null
    kill "$pid" 2>/dev/null
    wait "$pid" 2>/dev/null

    cat "$log"
}

rm -rf "$work_dir"
mkdir -p "$work_dir"

echo
echo "Extraction and full cleanup of every volume"
echo "-------------------------------------------"

if [ ! -d "$fixtures_dir" ]; then
    echo "  Fixtures missing. Run ./tests/make-fixtures.sh first."
    exit 1
fi

mkdir -p "$work_dir/extract"
# Parallel indexed arrays rather than an associative array, so this still runs
# on the bash 3.2 that ships with macOS.
fixture_names=()
fixture_counts=()
for dir in "$fixtures_dir"/*/; do
    name=$(basename "$dir")
    cp -R "$dir" "$work_dir/extract/$name"
    fixture_names+=("$name")
    fixture_counts+=("$(find "$work_dir/extract/$name" -type f | wc -l | tr -d ' ')")
done

run_scan "$work_dir/extract" DELETE_RAR_AFTER_EXTRACTION=true > /dev/null

for i in "${!fixture_names[@]}"; do
    name="${fixture_names[$i]}"
    remaining=$(find "$work_dir/extract/$name" -type f \
        \( -name '*.rar' -o -name '*.[r-z][0-9][0-9]' \) | wc -l | tr -d ' ')
    check "$name: all ${fixture_counts[$i]} volumes deleted" "0" "$remaining"

    # The payload should have survived the cleanup.
    payload=$(find "$work_dir/extract/$name" -type f \
        \( -name 'payload.bin' -o -name 'note.txt' \) | wc -l | tr -d ' ')
    check "$name: extracted payload intact" "1" "$payload"
done

echo
echo "===================================================="
printf 'passed: %d   failed: %d\n' "$passed" "$failed"
echo "===================================================="

[ "$failed" -eq 0 ]
