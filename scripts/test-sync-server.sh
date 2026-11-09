#!/bin/sh
# Two-way sync between two disposable Vaults: B is served by a real
# `andesite-server serve` process, A syncs to it with `andesite-server sync`.
set -eu
cd "$(dirname "$0")/.."
server="${ANDESITE_SERVER_BIN:-.build/debug/andesite-server}"
demo=$(mktemp -d /private/tmp/andesite-sync.XXXXXX)
mkdir -p "$demo/a" "$demo/b" "$demo/state-a" "$demo/state-b"
chmod 700 "$demo/state-a" "$demo/state-b"
export ANDESITE_API_TOKEN=$(openssl rand -hex 32)
pid=""
cleanup() {
  if test -n "$pid"; then kill -TERM "$pid" 2>/dev/null || :; wait "$pid" 2>/dev/null || :; fi
  rm -rf "$demo"
}
trap cleanup EXIT HUP INT TERM

printf 'line one\nline two\nline three\n' > "$demo/a/shared.md"
printf '# Only on B\n' > "$demo/b/from-b.md"

"$server" serve "$demo/b" --state "$demo/state-b" --port 0 > "$demo/serve.log" 2>&1 &
pid=$!
i=0
until grep -q 'api-ready' "$demo/serve.log"; do
  i=$((i + 1)); test "$i" -lt 100 || { cat "$demo/serve.log"; exit 1; }; sleep 0.1
done
url="http://127.0.0.1:$(sed -n 's/.*port=\([0-9]*\).*/\1/p' "$demo/serve.log")"
sync_a() { "$server" sync "$demo/a" "$url" --state "$demo/state-a"; }
settle() { sleep 1; } # let B's watcher capture direct file edits

sync_a
test "$(cat "$demo/b/shared.md")" = "$(cat "$demo/a/shared.md")"
test -f "$demo/a/from-b.md"

# Concurrent edits to different lines merge on both sides.
printf 'LINE ONE\nline two\nline three\n' > "$demo/a/shared.md"
printf 'line one\nline two\nLINE THREE\n' > "$demo/b/shared.md"
settle
sync_a
expected='LINE ONE
line two
LINE THREE'
test "$(cat "$demo/a/shared.md")" = "$expected"
test "$(cat "$demo/b/shared.md")" = "$expected"

# The same line edited on both sides: both versions survive.
printf 'from a\nline two\nLINE THREE\n' > "$demo/a/shared.md"
printf 'from b\nline two\nLINE THREE\n' > "$demo/b/shared.md"
settle
sync_a
test "$(ls "$demo/a" | grep -c 'conflict')" = 1
test "$(ls "$demo/b" | grep -c 'conflict')" = 1
cat "$demo/a/shared.md" "$demo/a/"*conflict* | grep -q 'from a'
cat "$demo/a/shared.md" "$demo/a/"*conflict* | grep -q 'from b'

# Unauthenticated and wrongly authenticated writes are refused.
test "$(curl -s -o /dev/null -w '%{http_code}' -X POST "$url/v1/sync/changes" -d '{}')" = 401
test "$(ANDESITE_API_TOKEN=$(openssl rand -hex 32) "$server" sync "$demo/a" "$url" --state "$demo/state-a" 2>&1 >/dev/null | grep -c 401)" = 1
diff -r -x .andesite "$demo/a" "$demo/b"
echo "sync smoke test passed"
