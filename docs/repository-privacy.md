# Repository privacy

Commit source code and synthetic test fixtures only. Keep real vaults, Obsidian
metadata, local settings, database state, credentials and environment files out
of Git and container build contexts. `.gitignore` and `.dockerignore` exclude
the standard local paths; they cannot detect private data saved under other
names or prevent `git add --force`.

Before publishing or pushing, install [Gitleaks](https://github.com/gitleaks/gitleaks)
(`brew install gitleaks` on macOS), then run:

```sh
./scripts/check-privacy.sh
```

This checks tracked filenames and commit identities, scans every reachable Git
ref for secrets, and scans tracked working-tree files (including staged new
files). Reports are redacted. Review changes as well: automated scanners cannot
prove that arbitrary notes or settings contain no personal information.

This repository uses the anonymous Git identity
`Andesite contributors <contributors@example.invalid>`.
Set it locally for future commits:

```sh
git config --local user.name 'Andesite contributors'
git config --local user.email 'contributors@example.invalid'
```

History sanitization changes commit IDs. Do not merge an old clone or branch
back into the sanitized history: it can restore removed information. Any
published copies, forks, caches, backups or clones must be cleaned separately.
If a real credential was exposed, revoke/rotate it; rewriting Git cannot make
it secret again. Local vaults and `.env` files are intentionally preserved.
