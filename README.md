# AndesiteServer (incomplete)

This repository is not a usable server. The executable intentionally exits with
an error instead of serving requests: authentication, recovery and the storage
engine are not implemented. Do not use it with real vaults.

The current milestone provides a Swift 6 package and an experimental SQLite
connection wrapper. It verifies SQLite >= 3.35, WAL and FTS5 at connection
startup, enables foreign keys and FULL synchronous mode, and supports bound
text statements and rollback on transaction failure. Callers must serialize
access and move blocking I/O off network event loops. This is not yet the
operational database or a filesystem/SQLite recovery protocol.

## Build and test

Install Swift 6.2 or later, SQLite development headers, pkg-config, and SQLite
with FTS5. Run `swift build` and `swift test`. The resolved dependency versions
are checked in. Hummingbird 2.28.0 and swift-markdown 0.9.0 are pinned; the
transitive swift-collections version is constrained to 1.3.0 because 1.7.5
failed with the locally installed Swift 6.4 prerelease toolchain.

The package has been built and its SQLite test run on macOS arm64 with the
local Swift 6.4 toolchain, and in the `swift:6.2` Linux arm64 container with
`libsqlite3-dev`. The local macOS build linked Homebrew's SQLite and emitted a
minimum deployment target warning; compatibility with older macOS releases has
not been verified. Linux filesystem guarantees and server behavior are not
verified by the SQLite test.
