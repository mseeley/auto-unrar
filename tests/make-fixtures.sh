#!/bin/bash
#
# Regenerates the archive fixtures used by run-tests.sh. Requires the non-free
# 'rar' binary (the 'unrar' package alone cannot create archives). Safe to
# re-run: every fixture directory is rebuilt from scratch.
#
# The fixtures are gitignored, so run this once before running the tests.
#
# Layouts covered:
#   old-style-volumes/   set.rar + set.r00..r99 + set.s00..s63
#                        Over 100 volumes, which is where the extension rolls
#                        from .rNN into .sNN (then .tNN, .uNN).
#   part-1digit/         show.part1.rar .. show.part6.rar
#   part-2digit/         show.part01.rar .. show.part43.rar
#   part-3digit/         show.part001.rar .. show.part178.rar
#                        rar chooses the padding width from the volume count,
#                        so these three are the only way to get real archives
#                        at each width. extract.sh must treat all of them as
#                        entry points.
#   single-volume/       solo.rar

set -e

tests_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
fixtures_dir="$tests_dir/fixtures"

if ! command -v rar &> /dev/null; then
    echo "Error: 'rar' is not installed. It is needed to build these fixtures."
    exit 1
fi

# Start from an empty directory so a fixture that has been renamed or dropped
# does not linger and get picked up by the tests.
rm -rf "${fixtures_dir:?}"
mkdir -p "$fixtures_dir"

# Builds one fixture directory: name, payload size, extra rar switches.
# Volume size is fixed at 1000 bytes so the payload size alone decides how many
# volumes (and therefore how many digits) rar produces.
build_fixture() {
    local name="$1" payload_bytes="$2" archive="$3"
    shift 3

    echo "Building $name/ ..."
    rm -rf "${fixtures_dir:?}/$name"
    mkdir -p "$fixtures_dir/$name"
    (
        cd "$fixtures_dir/$name"
        head -c "$payload_bytes" /dev/urandom > payload.bin
        rar a -inul "$@" "$archive" payload.bin
        rm -f payload.bin
    )
}

# -ma4 selects the RAR4 format, without which modern rar ignores -vn and falls
# back to .partNN.rar naming.
build_fixture old-style-volumes 150000 set.rar -ma4 -vn -v1000b

build_fixture part-1digit    5000 show.rar -v1000b
build_fixture part-2digit   36000 show.rar -v1000b
build_fixture part-3digit  150000 show.rar -v1000b

echo "Building single-volume/ ..."
rm -rf "${fixtures_dir:?}/single-volume"
mkdir -p "$fixtures_dir/single-volume"
(
    cd "$fixtures_dir/single-volume"
    echo "just one file" > note.txt
    rar a -inul solo.rar note.txt
    rm -f note.txt
)

echo
echo "Fixtures built:"
for dir in old-style-volumes part-1digit part-2digit part-3digit single-volume; do
    count=$(find "$fixtures_dir/$dir" -type f | wc -l | tr -d ' ')
    first=$(find "$fixtures_dir/$dir" -type f -exec basename {} \; | sort | head -1)
    printf '  %-20s %4s files (first: %s)\n' "$dir" "$count" "$first"
done
