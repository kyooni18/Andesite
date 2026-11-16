#!/bin/sh
# Audit reachable history and tracked working-tree files without printing secrets.
set -eu
cd "$(git rev-parse --show-toplevel)"
command -v gitleaks >/dev/null 2>&1 || {
  echo 'Install gitleaks first (macOS: brew install gitleaks).' >&2
  exit 1
}
python3 - <<'PY'
import pathlib
import re
import subprocess
import sys
import tempfile

def git(*args):
    return subprocess.check_output(['git', *args])

paths = set(git('ls-files', '-z').decode().split('\0'))
paths.update(git('log', '--all', '--format=', '--name-only').decode().splitlines())
forbidden = re.compile(
    r'(^|/)(vaults|\.obsidian|\.andesite|\.yeet|\.claude|\.swiftpm|\.build|'
    r'\.vscode|\.idea)(/|$)|'
    r'(^|/)(\.env(?:\..*)?|credentials\.json|secrets\.json|\.DS_Store)$|'
    r'\.(pem|key|p12|pfx|sqlite(?:-shm|-wal)?|db(?:-shm|-wal)?)$|'
    r'^(settings(/|$)|settings\.json$|data/|state/)'
)
bad = [p for p in paths if forbidden.search(p) and pathlib.PurePosixPath(p).name != '.env.example']
identities = set(git('log', '--all', '--format=%an <%ae>%n%cn <%ce>').decode().splitlines())
if bad or identities - {'Andesite contributors <contributors@example.invalid>'}:
    print('Privacy check failed: private filenames or non-anonymous commit identities found.', file=sys.stderr)
    sys.exit(1)

# Copy only tracked files into a private temporary directory. Never scan the
# actual local vault or .env, nor emit their contents into logs/reports.
with tempfile.TemporaryDirectory(prefix='andesite-privacy-') as temp:
    for name in git('ls-files', '-z').decode().split('\0'):
        if not name:
            continue
        source = pathlib.Path(name)
        if source.is_symlink() or not source.is_file():
            continue
        destination = pathlib.Path(temp) / name
        destination.parent.mkdir(parents=True, exist_ok=True)
        destination.write_bytes(source.read_bytes())
    subprocess.run(['gitleaks', 'dir', '--redact', '--no-banner', temp], check=True)
subprocess.run(['gitleaks', 'git', '--redact', '--no-banner', '--log-opts=--all --full-history', '.'], check=True)
print('Privacy checks passed for tracked files and all reachable Git history.')
PY
