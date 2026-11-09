#!/bin/sh
# Builds and tests on Linux in a disposable container (requires Docker).
# A 16 MiB tmpfs gives the full-disk test a real filesystem to fill.
# Usage: scripts/test-linux.sh [swift test arguments...]
set -eu
cd "$(dirname "$0")/.."
image="${ANDESITE_LINUX_IMAGE:-swift:6.2-noble}"
docker run --rm -v "$PWD":/src:ro -v andesite-linux-tests:/home/tester/work/.build \
  --tmpfs /small:size=16m,mode=1777 "$image" sh -c '
  set -e
  apt-get update -qq >/dev/null && apt-get install -y -qq libsqlite3-dev >/dev/null 2>&1
  useradd -m -u 1500 tester 2>/dev/null || true
  mkdir -p /home/tester/work
  cd /src && tar --exclude=./.build -cf - . | (cd /home/tester/work && tar -xf -)
  chown -R tester:tester /home/tester
  # Regular users get umask 002 here; group-writable vault ancestors are
  # (correctly) refused, so use the usual 022.
  su tester -c "umask 022; cd /home/tester/work && ANDESITE_TEST_SMALL_FS=/small swift test $*"' sh "$@"
