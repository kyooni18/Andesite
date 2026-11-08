#!/usr/bin/env python3
"""Opt-in per-vault macOS launchd agent for the Andesite watch CLI.

No vault is selected or enabled automatically; passing both explicit absolute
directories to install is mandatory. No source notes are modified by installer.
"""
import argparse
import hashlib
import os
import plistlib
import re
import stat
import subprocess
import sys
import time
import tempfile
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent


def verified_directory(raw: str, private: bool = False) -> Path:
    if not raw.startswith("/") or "/../" in raw or "/./" in raw or "//" in raw or raw.endswith("/"):
        raise ValueError("use an absolute physical directory without . / .. / symlinks")
    path = Path(raw)
    if path.resolve(strict=True) != path or not path.is_dir():
        raise ValueError(f"not a physical directory: {raw}")
    mode = path.stat()
    if mode.st_uid != os.geteuid():
        raise ValueError(f"directory must belong to current user: {raw}")
    if private and (stat.S_IMODE(mode.st_mode) & 0o077):
        raise ValueError(f"state directory must have mode 0700: {raw}")
    return path


def job_label(vault: Path) -> str:
    token = hashlib.sha256(str(vault).encode("utf-8")).hexdigest()[:16]
    return f"org.andesite.watch.{token}"


def launchctl(*args: str, check: bool = False) -> subprocess.CompletedProcess:
    return subprocess.run(["/bin/launchctl", *args], check=check, capture_output=True, text=True)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("command", choices=["install", "status", "uninstall"])
    parser.add_argument("--vault", required=True, help="existing absolute physical vault directory")
    parser.add_argument("--state", help="existing private state directory (required for install)")
    parser.add_argument("--binary", help="absolute path to built andesite-server")
    args = parser.parse_args()
    try:
        vault = verified_directory(args.vault)
        label = job_label(vault)
        domain = f"gui/{os.getuid()}"
        service = f"{domain}/{label}"
        agents = Path.home() / "Library/LaunchAgents"
        destination = agents / (label + ".plist")
        if args.command == "status":
            proc = launchctl("print", service)
            print(proc.stdout if proc.returncode == 0 else proc.stderr, end="")
            return proc.returncode
        if args.command == "uninstall":
            running = launchctl("print", service)
            match = re.search(r"\bpid = (\d+)\b", running.stdout) if running.returncode == 0 else None
            pid = int(match.group(1)) if match else None
            if running.returncode == 0:
                proc = launchctl("bootout", service)
                if proc.returncode != 0:
                    raise RuntimeError(f"launchctl bootout failed: {proc.stderr.strip()}")
            if pid:
                deadline = time.monotonic() + 20
                while time.monotonic() < deadline:
                    try:
                        os.kill(pid, 0)
                    except ProcessLookupError:
                        break
                    time.sleep(0.1)
                else:
                    raise RuntimeError(f"agent process {pid} did not exit after bootout; inspect before removing the state")
            if destination.exists():
                destination.unlink()
                print(f"Removed {destination}; watcher exited")
            return 0
        if not args.state:
            raise ValueError("--state is required to install")
        state = verified_directory(args.state, private=True)
        if vault == state or state in vault.parents or vault in state.parents:
            raise ValueError("vault and private state directories must not overlap")
        if args.binary:
            binary = Path(args.binary)
            if not binary.is_absolute():
                raise ValueError("--binary must be absolute")
        else:
            release = REPO / ".build/release/andesite-server"
            debug = REPO / ".build/debug/andesite-server"
            binary = release if release.is_file() else debug
        binary = binary.resolve(strict=True)
        if not binary.is_file() or not os.access(binary, os.X_OK):
            raise ValueError(f"build Andesite before installing; binary missing: {binary}")
        if destination.exists() or launchctl("print", service).returncode == 0:
            raise ValueError(f"agent already exists; uninstall it before changing settings: {label}")
        logs = Path.home() / "Library/Logs/Andesite"
        agents.mkdir(parents=True, exist_ok=True)
        logs.mkdir(parents=True, exist_ok=True, mode=0o700)
        data = {
            "Label": label,
            "ProgramArguments": [str(binary), "watch", "--vault", str(vault), "--state", str(state)],
            "RunAtLoad": True,
            "KeepAlive": {"SuccessfulExit": False},
            "ThrottleInterval": 20,
            "ProcessType": "Background",
            "StandardOutPath": str(logs / (label + ".out.log")),
            "StandardErrorPath": str(logs / (label + ".err.log")),
        }
        temporary = None
        try:
            with tempfile.NamedTemporaryFile(dir=agents, prefix=label + ".", suffix=".tmp", delete=False) as f:
                temporary = Path(f.name)
                plistlib.dump(data, f)
                os.fchmod(f.fileno(), 0o644)
                f.flush()
                os.fsync(f.fileno())
            os.replace(temporary, destination)
        finally:
            if temporary and temporary.exists():
                temporary.unlink()
        proc = launchctl("bootstrap", domain, str(destination))
        if proc.returncode != 0:
            raise RuntimeError(f"launchctl bootstrap failed: {proc.stderr.strip()}; plist remains at {destination}")
        print(f"Installed and started {label}")
        print(f"Agent: {destination}")
        print(f"Logs: {logs / (label + '.out.log')}")
        print("The watcher owns this state directory exclusively until stopped.")
        return 0
    except (ValueError, OSError, RuntimeError) as error:
        print(f"Andesite launch agent: {error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
