#!/bin/sh
# Reproducible Hummingbird/Unix-relay API contract smoke test.
# Only temporary Vaults; no existing note data or long-lived agent is used.
set -eu
cd "$(dirname "$0")/.."

demo=$(mktemp -d /private/tmp/andesite-api-contract.XXXXXX)
mkdir "$demo/vault"
printf '# Sample\napi-contract-search-unique\n' > "$demo/vault/note.md"
port=$(python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1]); s.close()')
token=$(openssl rand -hex 32)
state=$("${ANDESITE_SERVER_BIN:-.build/debug/andesite-server}" vault-state "$demo/vault")
watch_pid=""
api_pid=""

cleanup() {
  if test -n "$api_pid"; then kill -TERM "$api_pid" 2>/dev/null || :; wait "$api_pid" 2>/dev/null || :; fi
  if test -n "$watch_pid"; then kill -TERM "$watch_pid" 2>/dev/null || :; wait "$watch_pid" 2>/dev/null || :; fi
  rm -rf "$demo"
  if test -n "$state"; then rm -rf "$state"; fi
}
trap cleanup EXIT HUP INT TERM

status() {
  curl --silent --show-error --max-time 4 -o "$demo/response" -w '%{http_code}' "$@"
}

"${ANDESITE_SERVER_BIN:-.build/debug/andesite-server}" vault-watch "$demo/vault" > "$demo/watch.log" 2>&1 &
watch_pid=$!
sleep 2
ANDESITE_API_TOKEN="$token" "${ANDESITE_SERVER_BIN:-.build/debug/andesite-server}" api-serve "$demo/vault" --port "$port" > "$demo/api.log" 2>&1 &
api_pid=$!
sleep 2
url="http://127.0.0.1:$port"

test "$(status "$url/v1/status")" = 401
test "$(status -H 'Authorization: Bearer wrong' "$url/v1/status")" = 401
test "$(status -H "Authorization: Bearer $token" "$url/v1/status")" = 200
grep -q '"indexedReadable":true' "$demo/response"
test "$(status -H "Authorization: Bearer $token" "$url/v1/search?q=api-contract-search-unique")" = 200
grep -q 'Sample' "$demo/response"
test "$(status -H "Authorization: Bearer $token" "$url/v1/snapshots?path=note.md")" = 200
id=$(python3 - "$demo/response" <<'PY'
import json,sys
print(json.load(open(sys.argv[1]))["snapshots"][0]["snapshot"])
PY
)
test "$(status -H "Authorization: Bearer $token" "$url/v1/snapshots/$id/content")" = 200
grep -q 'api-contract-search-unique' "$demo/response"
test "$(status -X POST -H "Authorization: Bearer $token" "$url/v1/status")" = 405
test "$(status -H "Authorization: Bearer $token" -H 'Content-Length: 0' "$url/v1/status")" = 400
test "$(status -H "Authorization: Bearer $token" "$url/v1/invalid")" = 404

# Reject extended tokens even if they begin with a correct token.
extended="$token"
i=0
while test "$i" -lt 256; do
  extended="$extended"a
  i=$((i+1))
done
test "$(status -H "Authorization: Bearer $extended" "$url/v1/status")" = 401

# After watch stops, the HTTP API cannot serve stale indexed data.
kill -TERM "$watch_pid"
wait "$watch_pid"
watch_pid=""
test "$(status -H "Authorization: Bearer $token" "$url/v1/status")" = 503
grep -q 'vault_watcher_unavailable' "$demo/response"

# Explicitly validate the listener is loopback-only.
lsof -nP -a -p "$api_pid" -iTCP -sTCP:LISTEN | grep -q "127.0.0.1:$port"
echo "API_CONTRACT_PASS local_port=$port"
