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
# The window-capture helper is the SAME binary at a second path, with only its
# linker signature. Deliberately no stable identifier: macOS keys privacy
# grants (TCC) to a signed identity or, for ad-hoc tools, to the path — and
# dist/unbiased-ax has its own record from the Accessibility grant, which
# makes it its own client for Screen Recording too, a grant nobody gave it.
# Measured: ScreenCaptureKit from that path stalls or returns blank frames,
# while the identical binary at any other path is attributed to the app that
# spawned it — which has Screen Recording — and answers in ~100ms.
cp .build/release/unbiased-ax dist/unbiased-ax-capture
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
