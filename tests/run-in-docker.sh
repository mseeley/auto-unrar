#!/bin/bash
#
# Runs the test suite inside the Docker image, against the extract.sh that the
# image actually ships. Results on the host are only suggestive: the container
# is Debian with GNU find, bash 5 and a case-sensitive filesystem, and a macOS
# host matches it on none of those.
#
#   ./tests/run-in-docker.sh
#
# Fixtures are built on the host and mounted in read only, because Debian has
# no 'rar' package, only 'unrar', so the container cannot create archives. The
# scratch directory lives inside the container so the run leaves nothing behind
# and cannot write root-owned files onto the host.

set -e

tests_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_dir="$(dirname "$tests_dir")"
image="auto-unrar-tests"

if ! command -v docker &> /dev/null; then
    echo "Error: docker is not installed."
    exit 1
fi

if [ ! -d "$tests_dir/fixtures" ]; then
    echo "Fixtures missing, building them on the host first."
    "$tests_dir/make-fixtures.sh"
    echo
fi

# Progress stays on screen: the apt step takes long enough that a quiet build
# is hard to tell apart from a hung one.
echo "Building $image ..."
docker build -t "$image" "$repo_dir"

echo "Running tests in $image ..."
echo
exec docker run --rm \
    -v "$tests_dir:/tests:ro" \
    -e EXTRACT_SH=/extract.sh \
    -e TEST_WORK_DIR=/tmp/work \
    "$image" \
    bash /tests/run-tests.sh
