#!/bin/sh
# Serves /data/vault (state in /data/state) and forwards port 8790 to it.
set -eu
: "${ANDESITE_API_TOKEN:?set ANDESITE_API_TOKEN to 64 hex digits (openssl rand -hex 32)}"
mkdir -p /data/vault /data/state
chown andesite:andesite /data /data/vault /data/state
chmod 755 /data /data/vault
chmod 700 /data/state

run() { setpriv --reuid=andesite --regid=andesite --init-groups --reset-env \
  env HOME=/home/andesite ANDESITE_API_TOKEN="$ANDESITE_API_TOKEN" "$@"; }

run sh -c 'umask 022; exec andesite-server serve /data/vault --state /data/state --port 8788' &
server=$!
run /usr/sbin/nginx -c /etc/nginx/andesite.conf -g 'daemon off;' &
proxy=$!
trap 'kill -TERM $server $proxy 2>/dev/null; wait' INT TERM
# Stop the container if either process exits.
while kill -0 $server 2>/dev/null && kill -0 $proxy 2>/dev/null; do sleep 1; done
kill -TERM $server $proxy 2>/dev/null || :
wait
exit 1
