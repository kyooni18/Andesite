import Foundation

public enum CatalogMigrationError: Error, Equatable {
    case unsupportedVersion(Int)
    case invalidVersion
}

/// Initial catalog subset. Migrations do not touch vault files. A catalog is not
/// safe to use as a sync service until general operations/recovery and the
/// remaining protocol tables are implemented (the local restore journal is v6). Call only with exclusive process ownership and a backup.
public enum CatalogSchema {
    public static let currentVersion = 7

    public static func migrate(_ db: SQLiteConnection) throws {
        try db.transaction {
            guard let text = try db.scalarText("PRAGMA user_version"), let version = Int(text) else {
                throw CatalogMigrationError.invalidVersion
            }
            guard version <= currentVersion else { throw CatalogMigrationError.unsupportedVersion(version) }
            if version == 0 {
                for statement in versionOne { try db.execute(statement) }
                try db.execute("PRAGMA user_version=1")
            }
            if version < 2 {
                for statement in versionTwo { try db.execute(statement) }
                try db.execute("PRAGMA user_version=2")
            }
            if version < 3 {
                try db.execute("ALTER TABLE revisions ADD COLUMN fs_hint BLOB")
                try db.execute("PRAGMA user_version=3")
            }
            if version < 4 {
                try db.execute("""
                    CREATE TABLE incidents (
                      vault_id BLOB NOT NULL REFERENCES vaults(id), id BLOB NOT NULL CHECK(length(id)=16),
                      path TEXT NOT NULL, path_key TEXT NOT NULL, entry_id BLOB,
                      content_hash BLOB NOT NULL REFERENCES objects(hash), fs_hint BLOB NOT NULL,
                      status TEXT NOT NULL CHECK(status IN ('open','resolved')), observed_at TEXT NOT NULL,
                      PRIMARY KEY(vault_id,id), FOREIGN KEY(vault_id,entry_id) REFERENCES entries(vault_id,id)
                    ) WITHOUT ROWID
                    """)
                try db.execute("CREATE INDEX incidents_open_path ON incidents(vault_id,path_key) WHERE status='open'")
                try db.execute("PRAGMA user_version=4")
            }
            if version < 5 {
                for statement in versionFive { try db.execute(statement) }
                try db.execute("PRAGMA user_version=5")
            }
            if version < 6 {
                try db.execute("""
                    CREATE TABLE mutation_journal (
                      vault_id BLOB NOT NULL REFERENCES vaults(id), id BLOB NOT NULL CHECK(length(id)=16),
                      entry_id BLOB NOT NULL, snapshot_id BLOB NOT NULL, preimage_id BLOB NOT NULL,
                      parent_revision BLOB NOT NULL CHECK(length(parent_revision)=16), revision_id BLOB NOT NULL CHECK(length(revision_id)=16),
                      path TEXT NOT NULL, artifact TEXT NOT NULL, original_hint BLOB NOT NULL,
                      stage_hint BLOB, directories BLOB NOT NULL,
                      state TEXT NOT NULL CHECK(state IN ('prepared','staged','published','catalogued','completed','cancelled','quarantined')),
                      diagnostic TEXT NOT NULL DEFAULT '', created_at REAL NOT NULL,
                      PRIMARY KEY(vault_id,id), UNIQUE(vault_id,revision_id),
                      FOREIGN KEY(vault_id,parent_revision) REFERENCES revisions(vault_id,revision_id),
                      FOREIGN KEY(vault_id,entry_id) REFERENCES entries(vault_id,id),
                      FOREIGN KEY(vault_id,snapshot_id) REFERENCES recovery_snapshots(vault_id,id),
                      FOREIGN KEY(vault_id,preimage_id) REFERENCES recovery_snapshots(vault_id,id)
                    ) WITHOUT ROWID
                    """)
                try db.execute("CREATE INDEX mutation_journal_state ON mutation_journal(vault_id,state)")
            }
            if version < 6 { try db.execute("PRAGMA user_version=6") }
            if version < 7 {
                try db.execute("ALTER TABLE mutation_journal ADD COLUMN owned_hint BLOB")
                try db.execute("""
                    CREATE TABLE mutation_decisions (
                      vault_id BLOB NOT NULL, operation_id BLOB NOT NULL, strategy TEXT NOT NULL,
                      evidence BLOB NOT NULL, outcome TEXT NOT NULL, created_at REAL NOT NULL,
                      PRIMARY KEY(vault_id,operation_id),
                      FOREIGN KEY(vault_id,operation_id) REFERENCES mutation_journal(vault_id,id)
                    ) WITHOUT ROWID
                    """)
                try db.execute("""
                    CREATE TABLE mutation_retirements (
                      vault_id BLOB NOT NULL, operation_id BLOB NOT NULL, path TEXT NOT NULL,
                      hint BLOB NOT NULL, hash TEXT NOT NULL, state TEXT NOT NULL CHECK(state IN ('pending','retired')),
                      PRIMARY KEY(vault_id,operation_id),
                      FOREIGN KEY(vault_id,operation_id) REFERENCES mutation_journal(vault_id,id)
                    ) WITHOUT ROWID
                    """)
                try db.execute("""
                    CREATE TABLE mutation_versions (
                      vault_id BLOB NOT NULL, operation_id BLOB NOT NULL, role TEXT NOT NULL,
                      hash BLOB NOT NULL REFERENCES objects(hash), byte_length INTEGER NOT NULL CHECK(byte_length>=0),
                      path TEXT NOT NULL, hint BLOB,
                      PRIMARY KEY(vault_id,operation_id,role),
                      FOREIGN KEY(vault_id,operation_id) REFERENCES mutation_journal(vault_id,id)
                    ) WITHOUT ROWID
                    """)
                try db.execute("PRAGMA user_version=7")
            }
        }
    }

    private static let versionFive = [
        """
        CREATE TABLE snapshot_policy (
          vault_id BLOB PRIMARY KEY NOT NULL REFERENCES vaults(id),
          minimum_interval REAL NOT NULL CHECK(minimum_interval>=0),
          retention_seconds REAL NOT NULL CHECK(retention_seconds>0)
        ) WITHOUT ROWID
        """,
        """
        CREATE TABLE recovery_snapshots (
          vault_id BLOB NOT NULL, id BLOB NOT NULL CHECK(length(id)=16), entry_id BLOB NOT NULL,
          revision_id BLOB NOT NULL, content_hash BLOB NOT NULL REFERENCES objects(hash),
          byte_length INTEGER NOT NULL CHECK(byte_length>=0), path TEXT NOT NULL,
          ordinal INTEGER NOT NULL CHECK(ordinal>0),
          created_at REAL NOT NULL, expires_at REAL NOT NULL CHECK(expires_at>created_at),
          reason TEXT NOT NULL CHECK(reason IN ('interval','rename','deletion','shutdown','recovery')),
          PRIMARY KEY(vault_id,id), UNIQUE(vault_id,entry_id,revision_id), UNIQUE(vault_id,entry_id,ordinal),
          FOREIGN KEY(vault_id,entry_id) REFERENCES entries(vault_id,id),
          FOREIGN KEY(vault_id,revision_id) REFERENCES revisions(vault_id,revision_id)
        ) WITHOUT ROWID
        """,
        "CREATE INDEX recovery_snapshots_document ON recovery_snapshots(vault_id,entry_id,created_at)",
        "CREATE INDEX recovery_snapshots_expiry ON recovery_snapshots(vault_id,expires_at)"
    ]

    private static let versionTwo = [
        """
        CREATE TABLE document_metadata (
          vault_id BLOB NOT NULL, entry_id BLOB NOT NULL,
          indexed_revision BLOB NOT NULL CHECK(length(indexed_revision)=16), title TEXT NOT NULL,
          PRIMARY KEY(vault_id,entry_id), FOREIGN KEY(vault_id,entry_id) REFERENCES entries(vault_id,id)
        ) WITHOUT ROWID
        """,
        "CREATE VIRTUAL TABLE document_fts USING fts5(vault_id UNINDEXED,entry_id UNINDEXED,title,body,tokenize='unicode61')"
    ]

    private static let versionOne = [
        """
        CREATE TABLE vaults (
          id BLOB PRIMARY KEY NOT NULL CHECK(length(id)=16),
          root_config TEXT NOT NULL, epoch BLOB NOT NULL CHECK(length(epoch)=16),
          next_seq INTEGER NOT NULL DEFAULT 1 CHECK(next_seq>=1),
          min_seq INTEGER NOT NULL DEFAULT 0 CHECK(min_seq>=0),
          created_at TEXT NOT NULL, state TEXT NOT NULL
        ) WITHOUT ROWID
        """,
        """
        CREATE TABLE entries (
          vault_id BLOB NOT NULL REFERENCES vaults(id), id BLOB NOT NULL CHECK(length(id)=16),
          kind TEXT NOT NULL CHECK(kind IN ('markdown','attachment')),
          path TEXT, path_key TEXT, head_revision BLOB CHECK(head_revision IS NULL OR length(head_revision)=16),
          state TEXT NOT NULL CHECK(state IN ('reserved','live','deleted','retired')),
          fs_hint BLOB,
          PRIMARY KEY(vault_id,id),
          CHECK((state='live' AND path IS NOT NULL AND path_key IS NOT NULL AND head_revision IS NOT NULL)
             OR (state!='live' AND path IS NULL AND path_key IS NULL))
        ) WITHOUT ROWID
        """,
        "CREATE UNIQUE INDEX entries_live_path ON entries(vault_id,path_key) WHERE state='live'",
        """
        CREATE TABLE revisions (
          vault_id BLOB NOT NULL, entry_id BLOB NOT NULL, revision_id BLOB NOT NULL CHECK(length(revision_id)=16),
          parent1 BLOB CHECK(parent1 IS NULL OR length(parent1)=16), parent2 BLOB CHECK(parent2 IS NULL OR length(parent2)=16),
          content_hash BLOB CHECK(content_hash IS NULL OR length(content_hash)=32), byte_length INTEGER CHECK(byte_length IS NULL OR byte_length>=0),
          path TEXT NOT NULL, deleted INTEGER NOT NULL CHECK(deleted IN (0,1)), origin TEXT NOT NULL, created_at TEXT NOT NULL,
          PRIMARY KEY(vault_id,revision_id), FOREIGN KEY(vault_id,entry_id) REFERENCES entries(vault_id,id),
          CHECK((deleted=1 AND content_hash IS NULL AND byte_length IS NULL) OR (deleted=0 AND content_hash IS NOT NULL AND byte_length IS NOT NULL))
        ) WITHOUT ROWID
        """,
        """
        CREATE TABLE objects (
          hash BLOB PRIMARY KEY NOT NULL CHECK(length(hash)=32), length INTEGER NOT NULL CHECK(length>=0),
          durable_location TEXT NOT NULL, created_at TEXT NOT NULL
        ) WITHOUT ROWID
        """,
        """
        CREATE TABLE changes (
          vault_id BLOB NOT NULL, seq INTEGER NOT NULL CHECK(seq>0), entry_id BLOB NOT NULL,
          revision_id BLOB CHECK(revision_id IS NULL OR length(revision_id)=16),
          conflict_id BLOB CHECK(conflict_id IS NULL OR length(conflict_id)=16),
          type TEXT NOT NULL, operation_id BLOB CHECK(operation_id IS NULL OR length(operation_id)=16), payload_json TEXT NOT NULL,
          PRIMARY KEY(vault_id,seq), FOREIGN KEY(vault_id,entry_id) REFERENCES entries(vault_id,id)
        ) WITHOUT ROWID
        """,
        "CREATE INDEX changes_entry ON changes(vault_id,entry_id,seq)",
        """
        CREATE TABLE operations (
          vault_id BLOB NOT NULL REFERENCES vaults(id), client_id BLOB NOT NULL CHECK(length(client_id)=16),
          operation_id BLOB NOT NULL CHECK(length(operation_id)=16), request_hash BLOB NOT NULL CHECK(length(request_hash)=32),
          state TEXT NOT NULL, outcome_json TEXT, created_at TEXT NOT NULL,
          PRIMARY KEY(vault_id,client_id,operation_id)
        ) WITHOUT ROWID
        """
    ]
}
