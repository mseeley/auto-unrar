#!/bin/bash
#
# Tests for extract.sh. Run make-fixtures.sh first to build the archive
# fixtures, which are gitignored.
#
#   ./tests/make-fixtures.sh && ./tests/run-tests.sh
#
# To test the image rather than the host, use run-in-docker.sh. The host and
# the container disagree on things these tests depend on, notably GNU versus
# BSD find and whether the filesystem is case sensitive.
#
# Suite 1 checks which archives the scanner treats as entry points. It uses
# empty files, so it can cover part-number widths that would need thousands of
# real volumes to reproduce.
#
# Suite 2 runs real extractions with deletion enabled and checks that no
# archive volumes are left behind.
#
# Environment:
#   EXTRACT_SH      script under test, defaults to the one beside this directory
#   TEST_WORK_DIR   scratch directory, defaults to tests/work

# Job control, so each scan runs in its own process group and can be shut down
# along with the sleep it spawns. Killing the group avoids needing pkill, which
# the Debian image does not ship.
set -m

tests_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_dir="$(dirname "$tests_dir")"
fixtures_dir="$tests_dir/fixtures"
extract_sh="${EXTRACT_SH:-$repo_dir/extract.sh}"
work_dir="${TEST_WORK_DIR:-$tests_dir/work}"
scan_log="$work_dir/scan.log"

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

# Runs one scan of extract.sh over a directory, leaving its output in
# $scan_log. The script loops forever, so this waits for the output to stop
# growing (meaning the scan finished and it has gone to sleep) and then stops it.
#
# Deliberately not a command substitution: bash 5 turns job control off inside
# one, so the background job would not lead its own process group and the group
# kill below would quietly do nothing.
run_scan() {
    local source="$1"
    shift
    local log="$scan_log"
    rm -f "$log"

    env SOURCE_DIRECTORY="$source" SLEEP_TIME=30 "$@" \
        bash "$extract_sh" > "$log" 2>&1 &
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
}

# Was this archive treated as an entry point and handed to unrar?
was_attempted() {
    local name="$1"
    if grep -qF "Attempting to extract: $work_dir/select/$name " "$scan_log"; then
        echo "yes"
    else
        echo "no"
    fi
}

rm -rf "$work_dir"
mkdir -p "$work_dir"

echo
echo "Suite 1: multi-part entry point selection"
echo "-----------------------------------------"

mkdir -p "$work_dir/select"
# Empty files are enough here: we only care which ones the scanner picks up,
# not whether they extract.
entry_points=(
    plain.rar
    a.part1.rar
    b.part01.rar
    c.part001.rar
    d.part0001.rar
    e.part00001.rar
    UPPER.RAR
    Mixed.Rar
    upperparts.PART01.RAR
    mixedparts.Part001.Rar
)
later_volumes=(
    a.part2.rar
    a.part6.rar
    b.part02.rar
    b.part43.rar
    c.part002.rar
    c.part178.rar
    d.part0002.rar
    f.part10.rar
    g.part100.rar
    upperparts.PART02.RAR
    mixedparts.Part002.Rar
)
for name in "${entry_points[@]}" "${later_volumes[@]}"; do
    touch "$work_dir/select/$name"
done

run_scan "$work_dir/select"

for name in "${entry_points[@]}"; do
    check "$name is an entry point" "yes" "$(was_attempted "$name")"
done
for name in "${later_volumes[@]}"; do
    check "$name is skipped as a later volume" "no" "$(was_attempted "$name")"
done

echo
echo "Suite 2: extraction and full cleanup of every volume"
echo "----------------------------------------------------"

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
    # The encrypted fixture needs a password, so it cannot be extracted by a
    # plain no-password scan; Suite 3 covers it.
    [ "$name" = "encrypted" ] && continue
    cp -R "$dir" "$work_dir/extract/$name"
    fixture_names+=("$name")
    fixture_counts+=("$(find "$work_dir/extract/$name" -type f | wc -l | tr -d ' ')")
done

run_scan "$work_dir/extract" DELETE_RAR_AFTER_EXTRACTION=true

for i in "${!fixture_names[@]}"; do
    name="${fixture_names[$i]}"
    # -iname, or an upper case volume left behind would go uncounted and the
    # upper-case fixture would pass without proving anything.
    remaining=$(find "$work_dir/extract/$name" -type f \
        \( -iname '*.rar' -o -iname '*.[r-z][0-9][0-9]' \) | wc -l | tr -d ' ')
    check "$name: all ${fixture_counts[$i]} volumes deleted" "0" "$remaining"

    # The payload should have survived the cleanup.
    payload=$(find "$work_dir/extract/$name" -type f \
        \( -name 'payload.bin' -o -name 'note.txt' \) | wc -l | tr -d ' ')
    check "$name: extracted payload intact" "1" "$payload"
done

echo
echo "Suite 3: password-protected archives"
echo "------------------------------------"

if [ ! -d "$fixtures_dir/encrypted" ]; then
    echo "  encrypted fixture missing, skipping"
else
    # The fixture list holds the right password third, after two wrong ones and
    # before a fourth, so a successful extraction proves the loop tried and
    # rejected the earlier candidates and then stopped rather than running on.
    mkdir -p "$work_dir/enc-good"
    cp "$fixtures_dir/encrypted/enc.rar" "$work_dir/enc-good/"
    run_scan "$work_dir/enc-good" PASSWORD_FILE="$fixtures_dir/encrypted/passwords.txt"
    payload=$(find "$work_dir/enc-good" -name payload.txt | wc -l | tr -d ' ')
    check "password found after earlier wrong ones extracts the archive" "1" "$payload"

    # A list of only wrong passwords must not extract anything.
    mkdir -p "$work_dir/enc-bad"
    cp "$fixtures_dir/encrypted/enc.rar" "$work_dir/enc-bad/"
    printf 'nope-one\nnope-two\n' > "$work_dir/wrong-passwords.txt"
    run_scan "$work_dir/enc-bad" PASSWORD_FILE="$work_dir/wrong-passwords.txt"
    payload=$(find "$work_dir/enc-bad" -name payload.txt | wc -l | tr -d ' ')
    check "no matching password leaves it unextracted" "0" "$payload"

    # With no list at all the archive stays put, and the scan must not hang on a
    # password prompt.
    mkdir -p "$work_dir/enc-none"
    cp "$fixtures_dir/encrypted/enc.rar" "$work_dir/enc-none/"
    run_scan "$work_dir/enc-none" PASSWORD_FILE="$work_dir/does-not-exist.txt"
    payload=$(find "$work_dir/enc-none" -name payload.txt | wc -l | tr -d ' ')
    check "no password list leaves it unextracted" "0" "$payload"

    # A password failure on one archive must not stop the scan reaching others.
    # Two encrypted archives both fail against a wrong-only list; if the first
    # failure aborted the loop the second would never be attempted and so would
    # carry no error marker. Both markers being present proves the run visited
    # both regardless of the order find returns them in. A plain archive shares
    # the directory too, and its payload still has to come out.
    mkdir -p "$work_dir/enc-continue"
    cp "$fixtures_dir/encrypted/enc.rar" "$work_dir/enc-continue/first.rar"
    cp "$fixtures_dir/encrypted/enc.rar" "$work_dir/enc-continue/second.rar"
    cp "$fixtures_dir/single-volume/solo.rar" "$work_dir/enc-continue/"
    run_scan "$work_dir/enc-continue" PASSWORD_FILE="$work_dir/wrong-passwords.txt"
    first_errored=$(find "$work_dir/enc-continue" -name 'first.rar.extracted.error' | wc -l | tr -d ' ')
    second_errored=$(find "$work_dir/enc-continue" -name 'second.rar.extracted.error' | wc -l | tr -d ' ')
    plain_done=$(find "$work_dir/enc-continue" -name note.txt | wc -l | tr -d ' ')
    check "first failed archive records an error" "1" "$first_errored"
    check "second failed archive is still reached and records an error" "1" "$second_errored"
    check "plain archive alongside failures still extracts" "1" "$plain_done"
fi

echo
echo "===================================================="
printf 'passed: %d   failed: %d\n' "$passed" "$failed"
echo "===================================================="

[ "$failed" -eq 0 ]
