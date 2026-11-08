#!/usr/bin/env python3
"""Select, open, inspect or close one macOS Vault session.

Selection only writes <vault>/.andesite/vault.json. Opening explicitly starts
`andesite-server watch` for the Vault as a per-user launchd service.
Closing unloads the service and flushes pending snapshots; no vault contents
or history are deleted.
"""
import argparse
import hashlib
import os
import plistlib
import re
import stat
import subprocess
import sys
import tempfile
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent


def fail(message: str):
    raise ValueError(message)


def binary_path() -> Path:
    release = ROOT / ".build/release/andesite-server"
    debug = ROOT / ".build/debug/andesite-server"
    candidate = release if release.exists() else debug
    if not candidate.is_file():
        fail("build with 'swift build -c release' before opening a Vault")
    path = candidate.resolve(strict=True)
    if not os.access(path, os.X_OK):
        fail(f"binary is not executable: {path}")
    return path


def physical_vault(value: str) -> Path:
    if (not value.startswith("/") or value == "/" or value.endswith("/") or
            "//" in value or "\\" in value or "\0" in value or
            any(part in ("", ".", "..") for part in value[1:].split("/"))):
        fail("provide an absolute physical Vault directory without symlink components")
    path = Path(value)
    if path.resolve(strict=True) != path or not path.is_dir() or path.stat().st_uid != os.geteuid():
        fail(f"Vault must exist, be owned by the caller, and contain no symlinks: {value}")
    return path


def command(binary: Path, *args: str) -> str:
    result = subprocess.run([str(binary), *args], text=True, capture_output=True)
    if result.returncode != 0:
        fail(f"andesite-server {args[0]} failed: {result.stderr.strip()}")
    return result.stdout.strip()


def launchctl(*args: str):
    return subprocess.run(["/bin/launchctl", *args], text=True, capture_output=True)


def service_identity(state: str):
    token = hashlib.sha256(state.encode("utf-8")).hexdigest()[:20]
    label = "org.andesite.session." + token
    return label, f"gui/{os.getuid()}", f"gui/{os.getuid()}/{label}"


def existing_plist(path: Path, label: str):
    try:
        info = path.lstat()
    except FileNotFoundError:
        return None
    if (not stat.S_ISREG(info.st_mode) or info.st_nlink != 1 or
            info.st_uid != os.geteuid()):
        fail(f"unexpected or unsafe agent plist: {path}")
    with path.open("rb") as stream:
        data = plistlib.load(stream)
    args = data.get("ProgramArguments", [])
    if (data.get("Label") != label or len(args) != 3 or
            args[1] != "watch" or Path(args[0]).name != "andesite-server"):
        fail(f"agent file is not an Andesite Vault session: {path}")
    return data


def running(service: str) -> bool:
    result = launchctl("print", service)
    return result.returncode == 0 and "state = running" in result.stdout


def ensure_agent_paths():
    agents = Path.home() / "Library/LaunchAgents"
    logs = Path.home() / "Library/Logs/Andesite"
    agents.mkdir(parents=True, exist_ok=True)
    logs.mkdir(parents=True, exist_ok=True, mode=0o700)
    info = logs.lstat()
    if info.st_uid != os.geteuid() or stat.S_IMODE(info.st_mode) & 0o077:
        fail(f"log directory permissions are unsafe: {logs}")
    return agents, logs


def unload(service: str, plist: Path, label: str) -> bool:
    data = existing_plist(plist, label)
    current = launchctl("print", service)
    match = re.search(r"\bpid = (\d+)\b", current.stdout) if current.returncode == 0 else None
    pid = int(match.group(1)) if match else None
    if current.returncode == 0:
        result = launchctl("bootout", service)
        if result.returncode != 0:
            fail(f"launchctl bootout failed: {result.stderr.strip()}")
    if pid is not None:
        deadline = time.monotonic() + 20
        while time.monotonic() < deadline:
            try:
                os.kill(pid, 0)
            except ProcessLookupError:
                break
            time.sleep(0.1)
        else:
            fail(f"Vault watcher PID {pid} did not exit; inspect before changing its state")
    if data is not None:
        plist.unlink()
    return data is not None or current.returncode == 0


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("action", choices=["select", "open", "close", "status", "info"])
    parser.add_argument("vault", help="absolute physical Vault folder")
    args = parser.parse_args()
    try:
        vault = physical_vault(args.vault)
        binary = binary_path()
        if args.action == "select":
            print(command(binary, "add", str(vault)))
            return 0
        if args.action == "info":
            print(command(binary, "info", str(vault)))
            return 0

        # Read the physical-identity-derived external state path without
        # creating it or changing the Vault marker.
        state = command(binary, "state", str(vault))
        label, domain, service = service_identity(state)
        agents = Path.home() / "Library/LaunchAgents"
        destination = agents / (label + ".plist")

        if args.action == "close":
            if unload(service, destination, label):
                print(f"Closed Vault session: {vault}")
            else:
                print(f"Vault is not open: {vault}")
            return 0
        if args.action == "status":
            installed = launchctl("print", service).returncode == 0
            print(f"Vault: {vault}")
            print(f"State: {state}")
            print("Session: " + ("open" if running(service) else
                  "unavailable" if installed else "closed"))
            return 0

        if launchctl("print", service).returncode == 0:
            data = existing_plist(destination, label)
            if data is None or data["ProgramArguments"][2] != str(vault):
                fail("an existing watcher uses this directory identity at another path; close it before moving")
            if not running(service):
                fail("session is installed but not running; inspect logs and close it before retrying")
            print(f"Vault session already open: {vault}")
            return 0
        if existing_plist(destination, label) is not None:
            fail("stale session plist found; use close to remove it before opening")

        # Connect, reconcile and shut down before writing the launchd plist.
        # This must succeed; a failed scan must never become a background
        # service repeatedly restarting against unsafe user files.
        opened = command(binary, "open", str(vault))
        agents, logs = ensure_agent_paths()
        spec = {
            "Label": label,
            "ProgramArguments": [str(binary), "watch", str(vault)],
            "RunAtLoad": True,
            "KeepAlive": {"SuccessfulExit": False},
            "ThrottleInterval": 20,
            "ProcessType": "Background",
            "StandardOutPath": str(logs / (label + ".out.log")),
            "StandardErrorPath": str(logs / (label + ".err.log")),
        }
        temporary = None
        try:
            with tempfile.NamedTemporaryFile(
                dir=agents, prefix=label + ".", suffix=".tmp", delete=False
            ) as handle:
                temporary = Path(handle.name)
                plistlib.dump(spec, handle)
                os.fchmod(handle.fileno(), 0o644)
                handle.flush()
                os.fsync(handle.fileno())
            os.replace(temporary, destination)
        finally:
            if temporary is not None and temporary.exists():
                temporary.unlink()

        result = launchctl("bootstrap", domain, str(destination))
        if result.returncode != 0:
            fail(f"launchctl bootstrap failed: {result.stderr.strip()}; remove verified plist with close")

        # Report an open session only once the watcher logged its first scan.
        log = logs / (label + ".out.log")
        deadline = time.monotonic() + 10
        ready = False
        while time.monotonic() < deadline:
            if running(service) and log.exists() and "watch-ready" in log.read_text(errors="replace"):
                ready = True
                break
            if launchctl("print", service).returncode != 0:
                break
            time.sleep(0.1)
        if not ready:
            fail(f"watcher not ready: inspect {logs / (label + '.err.log')}; close to stop")
        print(opened)
        print(f"Opened Vault: {vault}")
        print(f"Close with: python3 scripts/andesite-vault.py close '{vault}'")
        return 0
    except (OSError, ValueError, plistlib.InvalidFileException) as error:
        print(f"Andesite Vault: {error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
