#!/bin/sh
# Packs the Walker support and privacy pages, with instructions for deploying them, into
# dist/walker-site.tar.gz for the kringum.is server.
set -eu
cd "$(dirname "$0")/.."
mkdir -p dist
# No macOS extended attributes or ._ files in the archive.
COPYFILE_DISABLE=1 tar --no-xattrs -czf dist/walker-site.tar.gz -C site INSTRUCTIONS-FOR-CLAUDE.md walker
tar -tzf dist/walker-site.tar.gz
echo "→ dist/walker-site.tar.gz ($(du -h dist/walker-site.tar.gz | cut -f1))"
