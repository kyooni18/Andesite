#!/bin/sh
# Two Mac Vaults, A and B, syncing through andesite-server running in an
# Apple Container (deploy/Containerfile), published on 127.0.0.1 only.
# Covers first sync, edits, merges, conflicts, renames, deletes, a container
# restart and authentication. Removes its container, volume and Vaults.
# Usage: scripts/test-container-sync.sh   (build the image first)
set -eu
cd "$(dirname "$0")/.."
client="${ANDESITE_SERVER_BIN:-.build/debug/andesite-server}"
image="${ANDESITE_IMAGE:-andesite-server}"
port="${ANDESITE_PORT:-8790}"
name="andesite-sync-test"
volume="andesite-sync-test"
url="http://127.0.0.1:$port"
# Not under /private/tmp: the Vault refuses ancestors it cannot verify there.
demo=$(mktemp -d "$HOME/.andesite-container-sync.XXXXXX")
mkdir -p "$demo/a" "$demo/b" "$demo/state-a" "$demo/state-b"
chmod 700 "$demo/state-a" "$demo/state-b"
export ANDESITE_API_TOKEN=$(openssl rand -hex 32)

cleanup() {
  container stop "$name" >/dev/null 2>&1 || :
  container rm "$name" >/dev/null 2>&1 || :
  container volume rm "$volume" >/dev/null 2>&1 || :
  rm -rf "$demo"
}
trap cleanup EXIT HUP INT TERM
cleanup_start() { container rm -f "$name" >/dev/null 2>&1 || :; container volume rm "$volume" >/dev/null 2>&1 || :; }
cleanup_start
container volume create "$volume" >/dev/null

start() {
  container run -d --name "$name" -p "127.0.0.1:$port:8790" \
    -e ANDESITE_API_TOKEN="$ANDESITE_API_TOKEN" -v "$volume:/data" "$image" >/dev/null
  i=0
  until test "$(curl -s -o /dev/null -w '%{http_code}' "$url/v1/sync/identity")" = 401; do
    i=$((i + 1)); test "$i" -lt 100 || { container logs "$name"; exit 1; }; sleep 0.2
  done
}
step() { echo "== $*"; }
sync() { "$client" sync "$demo/$1" "$url" --state "$demo/state-$1"; }
round() { sync a; sync b; sync a; } # A's changes reach B, and B's reach A
server_cat() { container exec "$name" cat "/data/vaults/main/$1"; }
same() { test "$(cat "$demo/a/$1")" = "$2" && test "$(cat "$demo/b/$1")" = "$2" && test "$(server_cat "$1")" = "$2"; }

start

step "first sync: notes from both sides reach everyone"
printf 'line one\nline two\nline three\n' > "$demo/a/shared.md"
mkdir -p "$demo/b/Projects"
printf '# Plan\n\nSee [[shared]].\n' > "$demo/b/Projects/Plan.md"
round
same shared.md 'line one
line two
line three'
same Projects/Plan.md '# Plan

See [[shared]].'

step "an edit on A reaches B"
printf 'line one\nline two, edited on A\nline three\n' > "$demo/a/shared.md"
round
same shared.md 'line one
line two, edited on A
line three'

step "edits to different lines on A and B merge"
printf 'LINE ONE\nline two, edited on A\nline three\n' > "$demo/a/shared.md"
printf 'line one\nline two, edited on A\nLINE THREE\n' > "$demo/b/shared.md"
round
same shared.md 'LINE ONE
line two, edited on A
LINE THREE'

step "the same line edited on both sides keeps both versions"
printf 'from A\nline two, edited on A\nLINE THREE\n' > "$demo/a/shared.md"
printf 'from B\nline two, edited on A\nLINE THREE\n' > "$demo/b/shared.md"
round
for side in a b; do
  test "$(ls "$demo/$side" | grep -c conflict)" = 1
  cat "$demo/$side/shared.md" "$demo/$side/"*conflict* | grep -q 'from A'
  cat "$demo/$side/shared.md" "$demo/$side/"*conflict* | grep -q 'from B'
done
rm "$demo/a/"*conflict*
round
test "$(ls "$demo/b" | grep -c conflict)" = 0

step "a rename on B and a delete on A"
mv "$demo/b/Projects/Plan.md" "$demo/b/Projects/Roadmap.md"
rm "$demo/a/shared.md"
round
test -f "$demo/a/Projects/Roadmap.md" && test ! -e "$demo/a/Projects/Plan.md"
test ! -e "$demo/b/shared.md"
container exec "$name" test ! -e /data/vaults/main/shared.md

step "the server keeps everything across a restart"
container stop "$name" >/dev/null && container rm "$name" >/dev/null
start
printf 'after restart\n' > "$demo/b/later.md"
round
same later.md 'after restart'
test "$(sync a)" = "sync received=0 sent=0 applied=0 merged=0 conflicts=0 pending=0"

step "requests without the right token are refused"
test "$(curl -s -o /dev/null -w '%{http_code}' -X POST "$url/v1/sync/changes" -d '{}')" = 401
test "$(ANDESITE_API_TOKEN=$(openssl rand -hex 32) "$client" sync "$demo/a" "$url" --state "$demo/state-a" 2>&1 >/dev/null | grep -c 401)" = 1

diff -r -x .andesite "$demo/a" "$demo/b"
echo "container sync test passed"
