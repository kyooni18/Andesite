#!/bin/sh
# Two disposable Vaults, no real notes.
set -eu
cd "$(dirname "$0")/.."
server=".build/debug/andesite-server"
if test -n "$(printenv ANDESITE_SERVER_BIN || true)"; then
  server="$ANDESITE_SERVER_BIN"
fi
demo=$(mktemp -d /private/tmp/andesite-sync-smoke.XXXXXX)
mkdir "$demo/source" "$demo/remote" "$demo/source-state" "$demo/remote-state"
chmod 700 "$demo/source-state" "$demo/remote-state"
printf '# Source\nchange-feed-one\n' > "$demo/source/note.md"
printf '# Receiver\nshould-remain-intact\n' > "$demo/remote/server.md"
token=$(openssl rand -hex 32)
port=$(python3 -c 'import socket;s=socket.socket();s.bind(("127.0.0.1",0));print(s.getsockname()[1]);s.close()')
watch=""
api=""
cleanup() {
  if test -n "$api"; then kill -TERM "$api" 2>/dev/null || :; wait "$api" 2>/dev/null || :; fi
  if test -n "$watch"; then kill -TERM "$watch" 2>/dev/null || :; wait "$watch" 2>/dev/null || :; fi
  rm -rf "$demo"
}
trap cleanup EXIT HUP INT TERM

"$server" vault-watch "$demo/remote" --state "$demo/remote-state" > "$demo/watch.log" 2>&1 &
watch=$!
sleep 2
ANDESITE_API_TOKEN="$token" "$server" api-serve "$demo/remote" --state "$demo/remote-state" --port "$port" > "$demo/api.log" 2>&1 &
api=$!
sleep 2
url="http://127.0.0.1:$port"

push() {
  ANDESITE_API_TOKEN="$token" "$server" sync-push "$demo/source" \
    --state "$demo/source-state" --to "$url" --peer "test-archive"
}
push > "$demo/first.log"
grep -q 'changes=1' "$demo/first.log"
grep -q 'archivedOnly=true' "$demo/first.log"
test "$(curl --silent -o "$demo/inbox.json" -w '%{http_code}' \
  -H "Authorization: Bearer $token" "$url/v1/sync/inbox")" = 200
python3 - "$demo/inbox.json" <<'PY'
import json,sys
data=json.load(open(sys.argv[1]))
assert data["total"]==1, data
assert data["sources"][0]["acknowledgedSequence"]==1, data
assert data["sources"][0]["snapshots"]>=1, data
assert data["appliedToVault"] is False
PY
# A receiver can retrieve the exact uploaded event + snapshot again;
# none of these reads apply remote edits to its active Vault.
python3 - "$demo/inbox.json" "$demo/origin.txt" <<'PYDOC'
import json,sys
item=json.load(open(sys.argv[1]))["sources"][0]
open(sys.argv[2],"w").write(item["sourceVault"]+"\n"+item["sourceEpoch"]+"\n")
PYDOC
source_id=$(sed -n '1p' "$demo/origin.txt")
epoch_id=$(sed -n '2p' "$demo/origin.txt")
test "$(curl --silent -o "$demo/received.json" -w '%{http_code}' \
  -H "Authorization: Bearer $token" \
  "$url/v1/sync/inbox/changes?source=$source_id&epoch=$epoch_id&after=0")" = 200
python3 - "$demo/received.json" <<'PYDOC'
import json,sys,base64,hashlib
data=json.load(open(sys.argv[1]))
assert len(data["changes"])==1
content=base64.b64decode(data["changes"][0]["contentBase64"])
assert b"change-feed-one" in content
assert hashlib.sha256(content).hexdigest()==data["changes"][0]["contentSHA256"]
PYDOC
test "$(curl --silent -o "$demo/snapshot-list.json" -w '%{http_code}' \
  -H "Authorization: Bearer $token" \
  "$url/v1/sync/inbox/snapshots?source=$source_id&epoch=$epoch_id")" = 200
snapshot_id=$(python3 - "$demo/snapshot-list.json" <<'PYDOC'
import json,sys
print(json.load(open(sys.argv[1]))["snapshots"][0]["snapshot"])
PYDOC
)
test "$(curl --silent -o "$demo/received-snapshot.json" -w '%{http_code}' \
  -H "Authorization: Bearer $token" \
  "$url/v1/sync/inbox/snapshots/$snapshot_id?source=$source_id&epoch=$epoch_id")" = 200
python3 - "$demo/received-snapshot.json" <<'PYDOC'
import json,sys,hashlib,base64
item=json.load(open(sys.argv[1]))
content=base64.b64decode(item["contentBase64"])
assert b"change-feed-one" in content
assert item["contentSHA256"]==hashlib.sha256(content).hexdigest()
PYDOC

push > "$demo/replay.log"
grep -q 'changes=0' "$demo/replay.log"
grep -q 'snapshots=0' "$demo/replay.log"
printf '# Updated\nchange-feed-two\n' > "$demo/source/note.md"
push > "$demo/second.log"
grep -q 'changes=1' "$demo/second.log"
test "$(curl --silent -o "$demo/inbox.json" -w '%{http_code}' \
  -H "Authorization: Bearer $token" "$url/v1/sync/inbox")" = 200
python3 - "$demo/inbox.json" <<'PY'
import json,sys
data=json.load(open(sys.argv[1]))
assert data["total"]==1, data
assert data["sources"][0]["acknowledgedSequence"]==2, data
assert data["appliedToVault"] is False
PY
grep -q 'should-remain-intact' "$demo/remote/server.md"
grep -q 'change-feed-two' "$demo/source/note.md"
test "$(curl --silent -o /dev/null -w '%{http_code}' "$url/v1/sync/inbox")" = 401
test "$(curl --silent -o /dev/null -w '%{http_code}' \
  -X POST -H "Authorization: Bearer $token" \
  -H 'Content-Type: application/json; charset=utf-8' \
  --data-binary '{"bad":"packet"}' "$url/v1/sync/changes")" = 400

kill -TERM "$api"; wait "$api" 2>/dev/null || :; api=""
kill -TERM "$watch"; wait "$watch" 2>/dev/null || :; watch=""
python3 - "$demo/remote-state/catalog.sqlite" <<'PY'
import sqlite3,sys
db=sqlite3.connect(sys.argv[1])
assert db.execute("select count(*) from sync_inbox_changes").fetchone()[0]==2
assert db.execute("select count(*) from sync_inbox_snapshots").fetchone()[0]>=1
assert db.execute("select count(*) from entries where state='live'").fetchone()[0]==1
assert db.execute("pragma integrity_check").fetchone()[0]=="ok"
PY
echo "SYNC_SERVER_CONTRACT_PASS (two changes, snapshots, replay, authenticated inbox, receiver intact)"
