# Vault selection and session lifecycle

## Selection vs. open

The per-Vault marker `<vault>/.andesite/vault.json` stores one
absolute path field, and nothing else. Registration through
`andesite-server vault-add ABSOLUTE_VAULT` does not open SQLite,
index files, or start monitoring.

To explicitly connect to a backend, run:

```sh
andesite-server vault-open /absolute/physical/vault
andesite-server vault-watch /absolute/physical/vault
```

`vault-open` connects, reconciles, flushes pending snapshots, and
closes. `vault-watch` runs FSEvents and the local read-only Unix
HTTP service until SIGINT/SIGTERM. Existing mutation-journal recovery and
serialized catalog ownership are preserved.

A Swift caller can use `VaultSession.init(vaultDirectory:)`,
`reconcile()`, `watch()`, and `close()`.
`watch()` blocks until its stop callback fires; call
`close()` afterward, including when errors occur, to flush
and release the state lock. Registration alone uses `VaultPathRegistry`
and never initializes `VaultSession`.

## Optional managed background session

On macOS, build and use the opt-in user LaunchAgent wrapper:

```sh
cd /Users/example/Code/Andesite
swift build -c release

python3 scripts/andesite-vault.py select /absolute/physical/vault
python3 scripts/andesite-vault.py open /absolute/physical/vault
python3 scripts/andesite-vault.py status /absolute/physical/vault
python3 scripts/andesite-vault.py close /absolute/physical/vault
```

`select` writes the path-only marker. `open` preflights
a synchronous connection, scan and shutdown, then installs a per-Vault
LaunchAgent running the existing FSEvents watcher. It waits for a functioning
same-user HTTP status response before claiming readiness. Opening an already
open session is idempotent. `close` unloads launchd, waits for
termination and snapshot flush, and removes only its own validated plist.
`status` does not open SQLite or register anything.

The service label is keyed by the stable state identity, not the path.
After a same-volume move, the Vault may be reopened at its new location
after closing the previous watcher. Always close before moving the folder:
FSEvents is not an online directory relocation service. The older
`andesite-launchagent.py` and explicit-state commands remain
available for manually configured deployments.

## State identity and relocation

Only the path is persisted in the Vault's `.andesite/vault.json`.
Default backend state lives outside the selected Vault:

```text
~/Library/Application Support/Andesite/States/
  v1-<SHA256(device, inode, birthtime)>/
    catalog.sqlite
    objects/
    server.lock
```

On macOS, the directory device, inode and birthtime provide a stable
identity across a rename **on the same filesystem**. State directories
are created only on an explicit open, with no-follow and private permissions.

The SQLite catalog records the previous root path and device/inode. A
verified same-volume rename with a matching Vault marker transactionally
rebinds only this root path. The Vault ID, epoch, snapshots, revisions,
object store, journal, and FTS are kept intact. Once the catalog opens,
the marker is updated to the selected absolute path.

A copy to another directory or storage volume has a different identity.
If the copied marker still refers to the original path, opening fails
with `stateHistoryRequiresMigration` rather than creating
an unrelated empty recovery catalog. Cross-volume migration of persistent
history is a separate explicit, verified operation not implemented here.
A user may intentionally re-register the copied folder as a new Vault,
but it will not share the original history.

Existing callers with their own `--state` directory can keep
that directory. Use
`vault-open ABSOLUTE_VAULT --state ABSOLUTE_PRIVATE_STATE` or
`vault-watch ABSOLUTE_VAULT --state ABSOLUTE_PRIVATE_STATE`.
There is no automatic search through previously configured state locations.

## Scope and limitations

No selection command starts an index or watcher, and closing does not
delete any note, snapshot, journal artifact or catalog. The existing
single-owner state lock and fail-closed safety checks remain. Never run
an explicit manual-state watcher and an automatic-state session for the
same Vault concurrently: their distinct state directories cannot coordinate.
Avoid overlapping Vault roots.

The default auto-state identity requires supported macOS inode birthtime.
Linux still supports explicit `--vault`/`--state` operations;
Linux inotify and safe automatic physical identity selection remain pending.
Unobserved intermediate edits, filesystem power loss, or cross-volume
migration cannot be recovered by this milestone.
