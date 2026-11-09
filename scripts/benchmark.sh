#!/bin/sh
# Times common operations on a generated, disposable Vault.
# Usage: scripts/benchmark.sh [notes=10000]   (build with: swift build -c release)
set -eu
cd "$(dirname "$0")/.."
server="${ANDESITE_SERVER_BIN:-.build/release/andesite-server}"
count="${1:-10000}"
demo=$(mktemp -d /private/tmp/andesite-bench.XXXXXX)
trap 'rm -rf "$demo"' EXIT
mkdir -p "$demo/vault" "$demo/state"
chmod 700 "$demo/state"
python3 - "$demo/vault" "$count" <<'PY'
import os, sys, random
root, count = sys.argv[1], int(sys.argv[2])
random.seed(1)
words = "alpha beta gamma delta epsilon zeta eta theta iota kappa lambda omicron".split()
for i in range(count):
    folder = os.path.join(root, f"folder{i % 50}")
    os.makedirs(folder, exist_ok=True)
    links = " ".join(f"[[Note {random.randrange(count)}]]" for _ in range(5))
    body = " ".join(random.choice(words) for _ in range(150))
    with open(os.path.join(folder, f"Note {i}.md"), "w") as f:
        f.write(f"---\ntags: [t{i % 20}]\nrating: {i % 5}\n---\n# Note {i}\n{body}\n{links}\n")
PY
run() { "$server" "$@" "$demo/vault" --state "$demo/state" >/dev/null; }
measure() { # measure LABEL COMMAND...
  label=$1; shift
  start=$(python3 -c 'import time; print(time.time())')
  "$@"
  end=$(python3 -c 'import time; print(time.time())')
  python3 -c "print(f'%-34s %8.2f s' % ('$label', $end - $start))"
}
echo "notes: $count ($(du -sh "$demo/vault" | cut -f1))"
measure "initial scan + index" run open
measure "no-op rescan" run open
printf 'edited\n' >> "$demo/vault/folder1/Note 1.md"
measure "rescan after one edit" run open
measure "search" sh -c "\"$server\" search \"$demo/vault\" 'gamma delta' --state \"$demo/state\" >/dev/null"
measure "backlinks of one note" sh -c "\"$server\" links \"$demo/vault\" 'folder7/Note 7.md' incoming --state \"$demo/state\" >/dev/null"
rev=$("$server" history "$demo/vault" 'folder7/Note 7.md' --state "$demo/state" | tail -1 | sed 's/revision=\([0-9a-f]*\).*/\1/')
measure "rename with link updates" sh -c "\"$server\" move \"$demo/vault\" 'folder7/Note 7.md' 'folder8/Renamed 7.md' $rev --state \"$demo/state\" >/dev/null"
du -sh "$demo/state" | sed 's/^/state size: /'
