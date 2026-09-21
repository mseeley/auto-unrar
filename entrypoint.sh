#!/bin/bash
#
# Runs the command as PUID:PGID, so that extracted files belong to whoever owns
# the media rather than to root. Leaving both unset keeps the container running
# as root, which is how this image behaved before they existed.
#
# Nothing is chowned. The source directory belongs to the host and is left
# exactly as it is found.

if [ -z "$PUID" ] && [ -z "$PGID" ]; then
    exec "$@"
fi

# When only one is given the other follows it, matching the user-private groups
# most Linux systems create.
puid="${PUID:-0}"
pgid="${PGID:-$puid}"

echo "Running as uid $puid, gid $pgid."
exec setpriv --reuid "$puid" --regid "$pgid" --clear-groups "$@"
