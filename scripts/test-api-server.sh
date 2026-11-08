#!/bin/sh
# HTTP API smoke test against a real `andesite-server serve` process.
# Uses only a disposable temporary Vault.
set -eu
cd "$(dirname "$0")/.."
server="${ANDESITE_SERVER_BIN:-.build/debug/andesite-server}"
demo=$(mktemp -d /private/tmp/andesite-api.XXXXXX)
mkdir "$demo/vault" "$demo/state"
chmod 700 "$demo/state"
printf '%s\n' '---' 'tags: [Project/Work, research]' 'rating: 5' '---' '# Sample' 'api-contract-search-unique' '[[Other note#Part|Label]]' > "$demo/vault/note.md"
printf '# Link target\n## Part\n' > "$demo/vault/Other note.md"
token=$(openssl rand -hex 32)
pid=""
cleanup() {
  if test -n "$pid"; then kill -TERM "$pid" 2>/dev/null || :; wait "$pid" 2>/dev/null || :; fi
  rm -rf "$demo"
}
trap cleanup EXIT HUP INT TERM

start() {
  : > "$demo/serve.log"
  ANDESITE_API_TOKEN="$token" "$server" serve "$demo/vault" --state "$demo/state" --port 0 > "$demo/serve.log" 2>&1 &
  pid=$!
  i=0
  until grep -q 'api-ready' "$demo/serve.log"; do
    i=$((i + 1)); test "$i" -lt 100 || { cat "$demo/serve.log"; exit 1; }; sleep 0.1
  done
  port=$(sed -n 's/.*api-ready host=127.0.0.1 port=\([0-9]*\).*/\1/p' "$demo/serve.log")
  url="http://127.0.0.1:$port"
}
call() { # call METHOD PATH [curl args...] -> prints status, body in $demo/body
  method=$1; path=$2; shift 2
  curl --silent --max-time 10 -o "$demo/body" -w '%{http_code}' -X "$method" \
    -H "Authorization: Bearer $token" "$@" "$url$path"
}
field() { python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))[sys.argv[2]])' "$demo/body" "$1"; }

start
test "$(curl --silent -o /dev/null -w '%{http_code}' "$url/v1/status")" = 401
test "$(call GET /v1/status)" = 200
test "$(call GET '/v1/search?q=api-contract-search-unique')" = 200 && grep -q '"note.md"' "$demo/body"
test "$(call GET '/v1/documents?tag=project')" = 200 && grep -q '"total":1' "$demo/body"
test "$(call GET '/v1/metadata?path=note.md')" = 200 && grep -q 'rating' "$demo/body"

test "$(call PUT '/v1/file?path=Inbox/new%20note.md' -H 'If-None-Match: *' --data-binary '# New
created over http')" = 201
rev=$(field revision)
test "$(call PUT '/v1/file?path=Inbox/new%20note.md' -H 'If-None-Match: *' --data-binary x)" = 409
test "$(call PUT '/v1/file?path=Inbox/new%20note.md' --data-binary x)" = 428
test "$(call PUT '/v1/file?path=Inbox/new%20note.md' -H "If-Match: \"$rev\"" --data-binary '# New
edited over http')" = 200
rev2=$(field revision)
test "$(call PUT '/v1/file?path=Inbox/new%20note.md' -H "If-Match: \"$rev\"" --data-binary stale)" = 412
grep -q "$rev2" "$demo/body"
grep -q 'edited over http' "$demo/vault/Inbox/new note.md"

# A killed server must restart into the same consistent state.
kill -KILL "$pid"; wait "$pid" 2>/dev/null || :; pid=""
start
test "$(call GET '/v1/file?path=Inbox/new%20note.md')" = 200 && grep -q 'edited over http' "$demo/body"
body="{\"path\":\"Inbox/new note.md\",\"to\":\"Archive/moved.md\",\"revision\":\"$rev2\"}"
code=$(call POST /v1/move --data-binary "$body"); test "$code" = 200
rev3=$(field revision)
test "$(call DELETE '/v1/file?path=Archive/moved.md' -H "If-Match: \"$rev3\"")" = 200
test ! -e "$demo/vault/Archive/moved.md"
body="{\"path\":\"Archive/moved.md\",\"revision\":\"$rev\"}"
code=$(call POST /v1/restore --data-binary "$body"); test "$code" = 200
grep -q 'created over http' "$demo/vault/Archive/moved.md"
test "$(call GET '/v1/history?path=Archive/moved.md')" = 200
test "$(python3 -c 'import json,sys; print(len(json.load(open(sys.argv[1]))["revisions"]))' "$demo/body")" = 5
test "$(call GET '/v1/file?path=../escape.md')" = 400
echo "api-server smoke test passed"
