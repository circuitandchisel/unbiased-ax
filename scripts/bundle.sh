#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
mkdir -p dist
cp .build/release/unbiased-ax dist/unbiased-ax
# Ad-hoc, with a STABLE identifier and a designated requirement on that
# identifier: the Accessibility grant is keyed to the signature, and this is
# what lets a rebuilt binary keep the grant instead of asking again.
codesign --force --sign - --identifier ai.unbiased.ax \
  --requirements '=designated => identifier "ai.unbiased.ax"' --timestamp=none dist/unbiased-ax
version=$(git describe --tags --always 2>/dev/null || echo 0.1.0)
cat > dist/manifest.json <<JSON
{
  "name": "unbiased-ax",
  "version": "$version",
  "protocolVersion": 1,
  "runtime": "native",
  "entry": "unbiased-ax",
  "args": [],
  "builtAt": "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
}
JSON
echo "dist/unbiased-ax ($(du -h dist/unbiased-ax | cut -f1)), dist/manifest.json"
