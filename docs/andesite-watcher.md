# Andesite continuous monitoring — macOS

## Implementation and behavior

`andesite-server watch --vault ABSOLUTE_VAULT --state ABSOLUTE_PRIVATE_STATE`
is a foreground, single-owner FSEvents-driven service. No HTTP port is opened.
`VaultRuntime` owns all observation, immutable object capture, SQLite/journal,
FTS and snapshot publication. FSEvents runs on a private dispatch queue and
only increments a thread-safe generation and records advisory event flags.
Paths supplied by event delivery are never used to bypass no-follow scanning.

The stream starts before the initial full scan. Every start/restart performs
a full reconciliation, including after abrupt termination while the watcher
was down. All delivered event hints cause another full scan, with a 400 ms
quiet-time debounce and a two-second maximum coalescing delay. An event delivered
during a scan remains queued for a subsequent scan. If FSEvents reports
`MustScanSubDirs`, kernel/user drops, wrapped IDs, mount/unmount, the normal
full rescan is performed and a diagnostic is emitted. A watched-root replacement
event stops the service without adopting the replacement directory. Regardless
of notifications, a fallback full scan runs every five minutes.

After an ordinary edit, the existing per-file policy determines when a recovery
snapshot is registered. A separate 15-second tick promotes *already durably
captured* heads when their minimum interval expires; it does not create new
source observations. The first valid capture always creates a snapshot. The
tick does nothing while catalog status is not `ready`, or when an unresolved
mutation prevents normal operations. On graceful SIGINT/SIGTERM shutdown,
observed pending heads are flushed through the existing shutdown path.

A scan failure logs a diagnostic and retries with bounded backoff (up to 30
seconds); it does not infer deletions or offer stale search results. The watch
process does not automatically resolve quarantined journal operations, restore
files, retire artifacts or prune history. Root replacement is fatal. Repeated
filesystem/catalog errors remain visible and require operator investigation.

The watcher keeps the state's exclusive process lock, so other CLI commands
using that state **cannot** run while the watch command is active. Stop it
before inspecting snapshots through the local CLI, then start it again. A future
read-only local API can solve this without defeating single-writer ownership.

FSEvents is a hint, not a comprehensive file edit journal. Transient edits not
present at a scan can be unobserved. The five-minute fallback bounds the time
until a persistent undelivered change is noticed while the process stays
healthy, not the number of versions captured. Offline changes are found on
restart. The underlying scan remains conservative about missing paths,
portability collisions, symlinks, unstable reads and ambiguous renames.

## Foreground smoke test (temporary vault only)

```sh
cd /Users/example/Code/Andesite
swift build
sample=$(mktemp -d /private/tmp/andesite-watch.XXXXXX)
mkdir "$sample/vault" "$sample/state"
chmod 700 "$sample/state"
printf '# Initial\nfirst\n' > "$sample/vault/note.md"
.build/debug/andesite-server watch --vault "$sample/vault" --state "$sample/state"
# In another terminal, edit "$sample/vault/note.md"; watch logs the scan.
# Ctrl-C ends the watch, flushing captured pending snapshots.
.build/debug/andesite-server snapshots --vault "$sample/vault" --state "$sample/state" note.md
```

## Optional per-vault LaunchAgent

First build an executable. The installer prefers a release build when present:

```sh
cd /Users/example/Code/Andesite
swift build -c release
python3 scripts/andesite-launchagent.py install \
  --vault /absolute/physical/path/to/test-vault \
  --state /absolute/physical/path/to/private-state
```

Both directories must already exist, and state must be owned by the current
user, mode 0700. The installer requires explicit paths and does **not** choose
a production Obsidian vault, create one, or enable an agent on its own.
It creates a per-vault plist in `~/Library/LaunchAgents`, and logs in
`~/Library/Logs/Andesite`. `launchd` restarts unsuccessful exits with
throttling; a clean SIGTERM stops the watcher. The service starts when
the user's `gui/<uid>` launchd domain is active; it is not a pre-login
system daemon.

```sh
python3 scripts/andesite-launchagent.py status --vault /absolute/physical/path/to/test-vault
python3 scripts/andesite-launchagent.py uninstall --vault /absolute/physical/path/to/test-vault
```

To upgrade the executable, unload/uninstall the LaunchAgent before replacing
the binary; rebuild, reinstall, then confirm `watch-ready` in the logs. For
maintenance or CLI snapshot operations, stop the agent to release the state
lock. Never configure multiple watchers on the same vault using different
state directories. Keep the vault and private state on trusted local storage.

## Verification and limitations

The new Swift integration tests cover a live FSEvents stream and file changes,
rename/delete history, snapshot due promotion, periodic fallback and re-launch
after a real SIGKILL. Full suite: 34 tests on the development Mac; existing
mutation-journal SIGKILL coverage is retained. Dropped-event flags are handled
in code but actual kernel queue overflow and physical power loss have **not**
been reproduced. Linux inotify, network-backed filesystems and authenticated
read-only HTTP access are not implemented. The watcher is not an online backup
for intermediate versions that were never captured.
