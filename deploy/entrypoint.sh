#!/bin/sh
# Serves the vault /data/vaults/$ANDESITE_VAULT (default "main"; state in
# /data/state) and forwards port 8790 to it. Mount a host folder on
# /data/vaults to see the notes from the host.
set -eu
: "${ANDESITE_API_TOKEN:?set ANDESITE_API_TOKEN to 64 hex digits (openssl rand -hex 32)}"
vault="/data/vaults/${ANDESITE_VAULT:-main}"
mkdir -p /data/vaults /data/state
chown andesite:andesite /data /data/state
chmod 755 /data
chmod 700 /data/state

run() { setpriv --reuid=andesite --regid=andesite --init-groups --reset-env \
  env HOME=/home/andesite ANDESITE_API_TOKEN="$ANDESITE_API_TOKEN" "$@"; }

# The server only serves a vault its own user owns. A folder shared from the
# host can't be handed to that user, but one the user creates inside it can.
chown andesite:andesite /data/vaults 2>/dev/null || :
run mkdir -p "$vault"

run sh -c "umask 022; exec andesite-server serve '$vault' --state /data/state --port 8788" &
server=$!
run /usr/sbin/nginx -c /etc/nginx/andesite.conf -g 'daemon off;' &
proxy=$!
trap 'kill -TERM $server $proxy 2>/dev/null; wait' INT TERM
# Stop the container if either process exits.
while kill -0 $server 2>/dev/null && kill -0 $proxy 2>/dev/null; do sleep 1; done
kill -TERM $server $proxy 2>/dev/null || :
wait
exit 1
