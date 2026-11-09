#!/bin/sh
# Request latency while the server indexes a new vault and then while the
# watcher captures continuous outside edits, on a generated, disposable vault.
# Usage: scripts/latency.sh [notes=10000]   (build with: swift build -c release)
set -eu
cd "$(dirname "$0")/.."
server="${ANDESITE_SERVER_BIN:-.build/release/andesite-server}"
count="${1:-10000}"
port=18931
demo=$(mktemp -d /private/tmp/andesite-latency.XXXXXX)
mkdir -p "$demo/vault" "$demo/state"
chmod 700 "$demo/state"
python3 - "$demo/vault" "$count" <<'PY'
import os, sys, random
root, count = sys.argv[1], int(sys.argv[2])
random.seed(1)
words = "alpha beta gamma delta epsilon zeta eta theta iota kappa".split()
for i in range(count):
    folder = os.path.join(root, f"folder{i % 50}")
    os.makedirs(folder, exist_ok=True)
    with open(os.path.join(folder, f"Note {i}.md"), "w") as f:
        f.write(f"# Note {i}\n{' '.join(random.choice(words) for _ in range(150))}\n[[Note {random.randrange(count)}]]\n")
PY
token=$(openssl rand -hex 32)
ANDESITE_API_TOKEN=$token "$server" serve "$demo/vault" --state "$demo/state" --port $port > "$demo/serve.log" 2>&1 &
pid=$!
trap 'kill $pid 2>/dev/null; wait $pid 2>/dev/null; rm -rf "$demo"' EXIT
python3 - "$demo" "$token" "$port" <<'PY'
import sys, time, threading, urllib.request, urllib.error
demo, token, port = sys.argv[1], sys.argv[2], sys.argv[3]
base = f"http://127.0.0.1:{port}"
def call(method, path, body=None, headers={}):
    r = urllib.request.Request(base + path, data=body, method=method,
                               headers={"Authorization": "Bearer " + token, **headers})
    t = time.time()
    try: urllib.request.urlopen(r).read()
    except urllib.error.HTTPError as e:
        e.read(); failures[e.code] = failures.get(e.code, 0) + 1
    return time.time() - t
failures = {}
def ready(): return "watch-ready" in open(f"{demo}/serve.log").read()
start = time.time()
while True:
    try: call("GET", "/v1/status"); break
    except Exception: time.sleep(0.01)
print(f"API answering {time.time() - start:.2f} s after start")
def report(label, xs):
    xs = sorted(xs); q = lambda f: xs[max(0, int(len(xs) * f) - 1)] * 1000
    print(f"{label:28} p50 {q(.5):7.1f} ms  p95 {q(.95):7.1f} ms  max {xs[-1]*1000:7.1f} ms  (n={len(xs)})")
def errors(phase):
    if failures: print(f"  errors {phase}: " + ", ".join(f"HTTP {k} x{v}" for k, v in sorted(failures.items())))
    failures.clear()
reads, writes, n = [], [], 0
while not ready():
    reads.append(call("GET", "/v1/status"))
    writes.append(call("PUT", f"/v1/file?path=new/{n}.md", b"# New\n", {"If-None-Match": "*"})); n += 1
    time.sleep(0.02)
print(f"initial index done {time.time() - start:.2f} s after start")
if reads: report("read during initial index", reads); report("write during initial index", writes)
errors("during initial index (503 = index not ready yet)")
stop = False
def edit():
    i = 0
    while not stop:
        with open(f"{demo}/vault/folder{i % 50}/Note {i}.md", "a") as f: f.write("edit\n")
        i += 1; time.sleep(0.05)
editor = threading.Thread(target=edit); editor.start()
reads, writes, end = [], [], time.time() + 15
while time.time() < end:
    reads.append(call("GET", "/v1/search?q=gamma"))
    writes.append(call("PUT", f"/v1/file?path=new/{n}.md", b"# New\n", {"If-None-Match": "*"})); n += 1
    time.sleep(0.02)
stop = True; editor.join()
report("search during edits", reads); report("write during edits", writes)
errors("during edits")
PY
