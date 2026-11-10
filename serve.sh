#!/bin/sh
# Build the andesite-server image and deploy it on this machine as one container.
#
#   ./serve.sh                 build and run with docker (default)
#   ./serve.sh --container     build and run with Apple's `container` CLI
#
# Options:
#   --container    use Apple's `container` instead of docker
#   --name NAME    container name, also the named volume for its state (default: andesite)
#   --port PORT    host port, published on 127.0.0.1 only (default: 8790)
#   -h, --help     show this help
#
# The API token is ANDESITE_API_TOKEN in ./.env, generated on the first run.
# Keep .env private; it is gitignored. Server state lives in the named volume
# (/data), so redeploying keeps it. ./vaults on the host is mounted at /data/vaults.
set -eu

cd "$(dirname "$0")"

engine=docker
name=andesite
port=8790
while [ $# -gt 0 ]; do
  case "$1" in
    --container) engine=container ;;
    --name) name=${2:?serve.sh: --name needs a value}; shift ;;
    --port) port=${2:?serve.sh: --port needs a value}; shift ;;
    -h|--help) sed -n '2,15p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "serve.sh: unknown option: $1" >&2; exit 2 ;;
  esac
  shift
done

command -v "$engine" >/dev/null 2>&1 || { echo "serve.sh: '$engine' is not installed" >&2; exit 1; }

umask 077
if ! grep -q '^ANDESITE_API_TOKEN=.' .env 2>/dev/null; then
  printf 'ANDESITE_API_TOKEN=%s\n' "$(openssl rand -hex 32)" >> .env
  echo "serve.sh: created .env with a new ANDESITE_API_TOKEN"
fi
chmod 600 .env
mkdir -p vaults

echo "serve.sh: building andesite-server with $engine"
"$engine" build -t andesite-server .

echo "serve.sh: replacing container $name"
if [ "$engine" = container ]; then
  container stop "$name" >/dev/null 2>&1 || true
  container delete "$name" >/dev/null 2>&1 || true
  container run -d --name "$name" \
    -p "127.0.0.1:$port:8790" \
    --env-file .env \
    -v "$name:/data" \
    -v "$PWD/vaults:/data/vaults" \
    andesite-server
else
  docker rm -f "$name" >/dev/null 2>&1 || true
  docker run -d --name "$name" --restart unless-stopped \
    -p "127.0.0.1:$port:8790" \
    --env-file .env \
    -v "$name:/data" \
    -v "$PWD/vaults:/data/vaults" \
    andesite-server
fi

echo "serve.sh: waiting for http://127.0.0.1:$port/"
code=000
for _ in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15; do
  code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 2 "http://127.0.0.1:$port/" || true)
  [ "$code" = 000 ] || break
  sleep 1
done
if [ "$code" = 000 ]; then
  echo "serve.sh: no response on port $port yet; check: $engine logs $name" >&2
  exit 1
fi
echo "serve.sh: $name is up (HTTP $code on port $port)"
