# Probes — the evidence behind docs/plans/2026-09-04-cross-space-design.md

Read-only Swift probes of the private remote-token mechanism, run from a
process with Accessibility access. Build one with:

    swiftc -O -o /tmp/brute brute.swift -framework AppKit -framework ApplicationServices

| probe | what it shows |
|---|---|
| `remote-token <app>` | system state, the REAL token bytes of public elements, and why a token built from a CGWindowID fails (`-25202`) |
| `brute <app> <maxId> [--walk]` | scan element ids, map `AXWindow` hits to window ids, walk an off-Space window. `onspace` picks whatever app has a window on the current Space |
| `identity` | an element rebuilt from a from-scratch token is `CFEqual` to the public `AXWindows` element — the stable-id guarantee |
| `webwalk <app>` | does Chromium serve web content for an OFF-Space window (yes: 477 elements, `AXWebArea` with 302 under it) |
| `focus` | the one MUTATING probe, run with the user's approval: focus Brave's address bar off-Space, read back, hand focus to the web area, and confirm nothing about the user's screen changed |

Token layout (little-endian): pid @0, 0 @4, `0x636f636f` 'coco' @8,
**element id** @12 (not the CGWindowID), 0 @16. App root: pid, 0, `0x61707020` 'app '.
