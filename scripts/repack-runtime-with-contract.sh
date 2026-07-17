#!/bin/sh
# Rebuilds one installer-ready Runtime archive with its versioned manifest and lifecycle overlay.
set -eu

if [ "$#" -ne 3 ]; then
  echo "usage: $0 <runtime-name> <input.tar.gz> <output.tar.gz>" >&2
  exit 2
fi

NAME=$1
INPUT=$2
OUTPUT=$3
OVERLAY_ROOT=${MDV_RUNTIME_OVERLAY_ROOT:?MDV_RUNTIME_OVERLAY_ROOT must point to the installer runtime-entrypoints directory}
OVERLAY="$OVERLAY_ROOT/$NAME"
WORK=$(mktemp -d)
TEMP_OUTPUT="$OUTPUT.installing"
trap 'rm -rf "$WORK" "$TEMP_OUTPUT"' EXIT HUP INT TERM

test -f "$INPUT"
test -f "$OVERLAY/manifest.yaml"
test -x "$OVERLAY/bin/mdv-$NAME"

tar -xzf "$INPUT" -C "$WORK"
cp -R "$OVERLAY/." "$WORK/"
chmod 755 "$WORK"
tar -czf "$TEMP_OUTPUT" -C "$WORK" .
mv "$TEMP_OUTPUT" "$OUTPUT"
sha256sum "$OUTPUT"
