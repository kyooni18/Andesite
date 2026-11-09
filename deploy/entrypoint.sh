#!/bin/sh
# Serves sync for every vault folder in /data/vaults (each vault's state in
# /data/state/<name>) and forwards port 8790 to it. Mount a host folder of
# vaults on /data/vaults. A vault "main" is created if there is none.
set -eu
: "${ANDESITE_API_TOKEN:?set ANDESITE_API_TOKEN to 64 hex digits (openssl rand -hex 32)}"
mkdir -p /data/vaults /data/state
# Before serve-all, the one vault's state was /data/state itself.
if [ -e /data/state/catalog.sqlite ]; then
  mkdir /data/state/main
  for item in /data/state/* /data/state/.[!.]*; do
    if [ -e "$item" ] && [ "$item" != /data/state/main ]; then mv "$item" /data/state/main/; fi
  done
fi
chown -R andesite:andesite /data/state
chmod 700 /data/state/*/ 2>/dev/null || :
chown andesite:andesite /data /data/state
chmod 755 /data
chmod 700 /data/state

run() { setpriv --reuid=andesite --regid=andesite --init-groups --reset-env \
  env HOME=/home/andesite ANDESITE_API_TOKEN="$ANDESITE_API_TOKEN" "$@"; }

# The server only serves a vault its own user owns. A folder shared from the
# host can't be handed to that user, but one the user creates inside it can.
chown andesite:andesite /data/vaults 2>/dev/null || :
[ -n "$(ls /data/vaults)" ] || run mkdir /data/vaults/main

run sh -c "umask 022; exec andesite-server serve-all /data/vaults --state /data/state --port 8788" &
server=$!
run /usr/sbin/nginx -c /etc/nginx/andesite.conf -g 'daemon off;' &
proxy=$!
trap 'kill -TERM $server $proxy 2>/dev/null; wait' INT TERM
# Stop the container if either process exits.
while kill -0 $server 2>/dev/null && kill -0 $proxy 2>/dev/null; do sleep 1; done
kill -TERM $server $proxy 2>/dev/null || :
wait
exit 1
