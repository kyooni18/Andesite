#!/bin/sh
# Reproducible Hummingbird/Unix-relay API contract smoke test.
# Only temporary Vaults; no existing note data or long-lived agent is used.
set -eu
cd "$(dirname "$0")/.."

demo=$(mktemp -d /private/tmp/andesite-api-contract.XXXXXX)
mkdir "$demo/vault"
printf '%s\n' '---' 'tags: [Project/Work, research]' 'rating: 5' 'status: active' '---' '# Sample' 'api-contract-search-unique' '[[Other note#Part|Label]]' '#Project/Work' > "$demo/vault/note.md"
printf '# Link target\n## Part\nA block ^block-3\n#project/other\n' > "$demo/vault/Other note.md"
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
  curl --silent --show-error --max-time 10 -o "$demo/response" -w '%{http_code}' "$@"
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
grep -q '"path":"note.md"' "$demo/response"
test "$(status -H "Authorization: Bearer $token" "$url/v1/documents?limit=10&offset=0")" = 200
grep -q '"total":2' "$demo/response"
document_id=$(python3 - "$demo/response" <<'PYDOC'
import json,sys
items=json.load(open(sys.argv[1]))["documents"]
print(next(item["document"] for item in items if item["path"]=="note.md"))
PYDOC
)
test "$(status -H "Authorization: Bearer $token" "$url/v1/documents/$document_id")" = 200
grep -q '"structureAvailable":true' "$demo/response"
grep -q 'Other note' "$demo/response"
test "$(status -H "Authorization: Bearer $token" "$url/v1/documents/$document_id/content")" = 200
grep -q 'api-contract-search-unique' "$demo/response"
# YAML Properties and tags must be revision-indexed and queryable.
test "$(status -H "Authorization: Bearer $token" "$url/v1/tags")" = 200
python3 - "$demo/response" <<'PYDOC'
import json,sys
tags={item["canonical"] for item in json.load(open(sys.argv[1]))["tags"]}
assert {"project/work","project/other","research"} <= tags, tags
PYDOC
test "$(status -H "Authorization: Bearer $token" "$url/v1/properties")" = 200
grep -q '"canonical":"rating"' "$demo/response"
test "$(status -H "Authorization: Bearer $token" "$url/v1/documents/$document_id/properties")" = 200
grep -q '"state":"valid"' "$demo/response"
grep -q '"type":"number"' "$demo/response"
test "$(status -H "Authorization: Bearer $token" "$url/v1/documents?tag=project")" = 200
grep -q '"total":2' "$demo/response"
test "$(status -H "Authorization: Bearer $token" "$url/v1/documents?tag=project/work&property=rating&value=5")" = 200
grep -q '"total":1' "$demo/response"
test "$(status -H "Authorization: Bearer $token" "$url/v1/search?q=api-contract-search-unique&tag=project")" = 200
grep -q 'note.md' "$demo/response"
test "$(status -H "Authorization: Bearer $token" "$url/v1/documents?tag=1984")" = 400

# Resolve a real target and its incoming mentions via the public HTTP API.
test "$(status -H "Authorization: Bearer $token" "$url/v1/documents?limit=10")" = 200
target_id=$(python3 - "$demo/response" <<'PYDOC'
import json,sys
items=json.load(open(sys.argv[1]))["documents"]
print(next(item["document"] for item in items if item["path"]=="Other note.md"))
PYDOC
)
test "$(status -H "Authorization: Bearer $token" "$url/v1/documents/$document_id/links")" = 200
grep -q '"status":"resolved"' "$demo/response"
grep -q '"fragmentStatus":"resolved"' "$demo/response"
test "$(status -H "Authorization: Bearer $token" "$url/v1/documents/$target_id/backlinks")" = 200
grep -q '"total":1' "$demo/response"
test "$(status -H "Authorization: Bearer $token" "$url/v1/documents/$target_id/backlinks?offset=-1")" = 400
test "$(status -H "Authorization: Bearer $token" "$url/v1/documents?limit=101")" = 400
test "$(status -H "Authorization: Bearer $token" "$url/v1/documents/00000000000000000000000000000000")" = 404
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

# One authorized existing-document edit, guarded by exact revision and
# journaled APFS exchange. Other mutating verbs remain disallowed.
test "$(status -H "Authorization: Bearer $token" "$url/v1/documents?limit=10")" = 200
original_revision=$(python3 - "$demo/response" <<'PYDOC'
import json,sys
notes=json.load(open(sys.argv[1]))["documents"]
print(next(note["revision"] for note in notes if note["path"]=="note.md"))
PYDOC
)
printf '# Updated via API\nchanged-through-edit-api\n' > "$demo/new-note.md"
test "$(status -X PUT -H 'Authorization: Bearer wrong' -H "If-Match: \"$original_revision\"" -H 'Content-Type: text/markdown; charset=utf-8' --data-binary @"$demo/new-note.md" "$url/v1/documents/$document_id/content")" = 401
test "$(status -X DELETE -H "Authorization: Bearer $token" "$url/v1/documents/$document_id/content")" = 405
test "$(status -X PUT -H "Authorization: Bearer $token" -H 'Content-Type: text/markdown; charset=utf-8' --data-binary @"$demo/new-note.md" "$url/v1/documents/$document_id/content")" = 428
test "$(status -X PUT -H "Authorization: Bearer $token" -H 'If-Match: "00000000000000000000000000000000"' -H 'Content-Type: text/markdown; charset=utf-8' --data-binary @"$demo/new-note.md" "$url/v1/documents/$document_id/content")" = 412
test "$(status -X PUT -H "Authorization: Bearer $token" -H "If-Match: \"$original_revision\"" -H 'Content-Type: application/octet-stream' --data-binary @"$demo/new-note.md" "$url/v1/documents/$document_id/content")" = 400
test "$(status -X PUT -H "Authorization: Bearer $token" -H "If-Match: \"$original_revision\"" -H 'Content-Type: text/markdown; charset=utf-8' --data-binary @"$demo/new-note.md" "$url/v1/documents/$document_id/content")" = 200
grep -q '"state":"completed"' "$demo/response"
grep -q '"indexReady":false' "$demo/response"
grep -q 'changed-through-edit-api' "$demo/vault/note.md"
# A second write with the old revision must either see pending indexing
# or fail the optimistic precondition, never overwrite a newer head.
again=$(status -X PUT -H "Authorization: Bearer $token" -H "If-Match: \"$original_revision\"" -H 'Content-Type: text/markdown; charset=utf-8' --data-binary @"$demo/new-note.md" "$url/v1/documents/$document_id/content")
test "$again" = 503 || test "$again" = 412

# Await the committed new head; the original snapshot remains immutable.
tries=0
while test "$tries" -lt 60; do
  test "$(status -H "Authorization: Bearer $token" "$url/v1/status")" = 200
  if grep -q '"indexedReadable":true' "$demo/response"; then break; fi
  sleep 0.15
  tries=$((tries+1))
done
test "$tries" -lt 60
test "$(status -H "Authorization: Bearer $token" "$url/v1/search?q=changed-through-edit-api")" = 200
grep -q 'Updated via API' "$demo/response"
test "$(status -H "Authorization: Bearer $token" "$url/v1/documents?tag=project/work")" = 200
grep -q '"total":0' "$demo/response"
test "$(status -H "Authorization: Bearer $token" "$url/v1/documents/$document_id/content")" = 200
grep -q 'changed-through-edit-api' "$demo/response"
test "$(status -X PUT -H "Authorization: Bearer $token" -H "If-Match: \"$original_revision\"" -H 'Content-Type: text/markdown; charset=utf-8' --data-binary @"$demo/new-note.md" "$url/v1/documents/$document_id/content")" = 412
test "$(status -H "Authorization: Bearer $token" "$url/v1/snapshots/$id/content")" = 200
grep -q 'api-contract-search-unique' "$demo/response"

# A body much larger than the private header limit must still be
# accepted when a single Unix recv coalesces headers and request bytes.
test "$(status -H "Authorization: Bearer $token" "$url/v1/documents?limit=10")" = 200
current_revision=$(python3 - "$demo/response" <<'PYDOC'
import json,sys
notes=json.load(open(sys.argv[1]))["documents"]
print(next(note["revision"] for note in notes if note["path"]=="note.md"))
PYDOC
)
python3 - "$demo/large.md" <<'PYDOC'
import sys
with open(sys.argv[1],"wb") as file:
    file.write(b"# Longer update\n" + b"x"*131072)
PYDOC
test "$(status -X PUT -H "Authorization: Bearer $token" -H "If-Match: \"$current_revision\"" -H 'Content-Type: text/markdown; charset=utf-8' --data-binary @"$demo/large.md" "$url/v1/documents/$document_id/content")" = 200
cmp "$demo/large.md" "$demo/vault/note.md"
# Explicit foreground success is independently reported to the work
# scheduler; FSEvents delivery is not the only scan trigger.
tries=0
while ! grep -q 'watch-foreground-mutation' "$demo/watch.log" && test "$tries" -lt 40; do
  sleep 0.1
  tries=$((tries+1))
done
grep -q 'watch-foreground-mutation' "$demo/watch.log"

# After watch stops, the HTTP API cannot serve stale indexed data.
kill -TERM "$watch_pid"
wait "$watch_pid"
watch_pid=""
test "$(status -H "Authorization: Bearer $token" "$url/v1/status")" = 503
grep -q 'vault_watcher_unavailable' "$demo/response"

# Explicitly validate the listener is loopback-only.
lsof -nP -a -p "$api_pid" -iTCP -sTCP:LISTEN | grep -q "127.0.0.1:$port"
echo "API_CONTRACT_PASS local_port=$port"
