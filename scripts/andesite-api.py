#!/usr/bin/env python3
"""Query Andesite's same-user, read-only Unix-socket HTTP API while watch runs.

No state lock, extra SQLite connection, TCP access or source-file modification.
"""
import argparse
import hashlib
import http.client
import json
import os
import socket
import stat
import sys
from pathlib import Path
from urllib.parse import urlencode


class UnixHTTPConnection(http.client.HTTPConnection):
    def __init__(self, socket_path: str):
        super().__init__("localhost", timeout=4)
        self.socket_path = socket_path

    def connect(self):
        self.sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        self.sock.settimeout(self.timeout)
        self.sock.connect(self.socket_path)


def socket_path(state: str) -> str:
    if not state.startswith("/") or "//" in state or "/../" in state or "/./" in state:
        raise ValueError("state must be an absolute physical path")
    root = Path(state)
    metadata = root.lstat()
    if (not stat.S_ISDIR(metadata.st_mode) or metadata.st_uid != os.geteuid() or
            stat.S_IMODE(metadata.st_mode) & 0o077 or root.resolve() != root):
        raise ValueError("state must be the current user's physical private directory")
    direct = str(root / "andesite-read.sock")
    if len(os.fsencode(direct)) < 104:
        return direct
    digest = hashlib.sha256(os.fsencode(state)).hexdigest()[:24]
    return f"/private/tmp/andesite-http-{os.geteuid()}/{digest}.sock"


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--state", required=True, help="absolute private state directory")
    sub = parser.add_subparsers(dest="command", required=True)
    sub.add_parser("status")
    for command in ("tags", "properties"):
        summary = sub.add_parser(command)
        summary.add_argument("--limit", type=int, default=50)
        summary.add_argument("--offset", type=int, default=0)
    documents = sub.add_parser("documents")
    documents.add_argument("--limit", type=int, default=50)
    documents.add_argument("--offset", type=int, default=0)
    documents.add_argument("--tag")
    documents.add_argument("--property")
    documents.add_argument("--value")
    document = sub.add_parser("document")
    document.add_argument("id")
    document_properties = sub.add_parser("document-properties")
    document_properties.add_argument("id")
    document_content = sub.add_parser("document-content")
    document_content.add_argument("id")
    for command in ("links", "backlinks"):
        link = sub.add_parser(command)
        link.add_argument("id")
        link.add_argument("--limit", type=int, default=50)
        link.add_argument("--offset", type=int, default=0)
    search = sub.add_parser("search")
    search.add_argument("phrase")
    search.add_argument("--limit", type=int, default=50)
    search.add_argument("--tag")
    search.add_argument("--property")
    search.add_argument("--value")
    listing = sub.add_parser("snapshots")
    selection = listing.add_mutually_exclusive_group()
    selection.add_argument("--path", help="historical vault-relative Markdown path")
    selection.add_argument("--document", help="stable document ID")
    listing.add_argument("--limit", type=int, default=50)
    listing.add_argument("--offset", type=int, default=0)
    info = sub.add_parser("snapshot")
    info.add_argument("id")
    content = sub.add_parser("content")
    content.add_argument("id")
    args = parser.parse_args()

    try:
        path = socket_path(args.state)
        if args.command == "status":
            url = "/v1/status"
        elif args.command in ("tags", "properties"):
            url = "/v1/" + args.command + "?" + urlencode({
                "limit": args.limit, "offset": args.offset})
        elif args.command == "documents":
            query = {"limit": args.limit, "offset": args.offset}
            query.update({k: v for k, v in {
                "tag": args.tag, "property": args.property, "value": args.value
            }.items() if v is not None})
            url = "/v1/documents?" + urlencode(query)
        elif args.command == "document":
            url = "/v1/documents/" + args.id
        elif args.command == "document-properties":
            url = "/v1/documents/" + args.id + "/properties"
        elif args.command == "document-content":
            url = "/v1/documents/" + args.id + "/content"
        elif args.command in ("links", "backlinks"):
            url = "/v1/documents/" + args.id + "/" + args.command + "?" + urlencode({
                "limit": args.limit, "offset": args.offset
            })
        elif args.command == "search":
            query = {"q": args.phrase, "limit": args.limit}
            query.update({k: v for k, v in {
                "tag": args.tag, "property": args.property, "value": args.value
            }.items() if v is not None})
            url = "/v1/search?" + urlencode(query)
        elif args.command == "snapshots":
            filters = {"limit": args.limit, "offset": args.offset}
            if args.path is not None:
                filters["path"] = args.path
            if args.document is not None:
                filters["document"] = args.document
            url = "/v1/snapshots?" + urlencode(filters)
        elif args.command == "snapshot":
            url = "/v1/snapshots/" + args.id
        else:
            url = "/v1/snapshots/" + args.id + "/content"
        conn = UnixHTTPConnection(path)
        try:
            conn.request("GET", url, headers={"Accept": "application/json"})
            response = conn.getresponse()
            data = response.read(1024 * 1024 + 8192)
            if response.status != 200:
                raise RuntimeError(f"HTTP {response.status}: {data.decode('utf-8', 'replace')}")
            if args.command in ("content", "document-content"):
                sys.stdout.buffer.write(data)
            else:
                print(json.dumps(json.loads(data), indent=2, ensure_ascii=False))
        finally:
            conn.close()
        return 0
    except (OSError, ValueError, RuntimeError, http.client.HTTPException) as error:
        print(f"Andesite API: {error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
