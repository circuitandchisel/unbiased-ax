# unbiased-ax

The accessibility bridge for unbiased-app's computer use. It gives an agent the
*structure* of what is on screen — running apps, their windows, and each app's
accessibility element tree as compact text with **stable ids** and **diffs** —
and lets it act on those elements. One long-running Swift process, newline-
delimited JSON over stdio, the same contract unbiased-app already uses for its
engine and its learning sidecar.

    swift build
    make test        # swift build && swift run unbiased-ax-tests — the only test runner
    make bundle      # dist/unbiased-ax (signed, identifier ai.unbiased.ax) + dist/manifest.json

## Why

Measured 2026-09-03, the same task — *play a YouTube video in my open Brave
tab*: unbiased-app took **27 tool calls and 6.7 minutes**, eleven of them
screenshots of a desktop that did not contain Brave (it was on another Space).
Codex took **7 calls and 67 seconds** by reading Brave's accessibility tree as
text, finding the selected tab, setting the URL bar, and confirming playback
from the window title. This is the piece that makes the second path possible.

## A session

    → {"id":1,"method":"raise","params":{"app":"Brave"}}
    ← {"id":1,"result":{"ok":true,"diff":"1 standard window \"YouTube - Brave\" {raise}\n2   toolbar\n3     text field \"Address and search bar\" = youtube.com/ {press}\n…"}}
    → {"id":2,"method":"find","params":{"app":"Brave","role":"text field","title":"address"}}
    ← {"id":2,"result":{"matches":["3     text field \"Address and search bar\" = youtube.com/ {press}"],"count":1}}
    → {"id":3,"method":"setValue","params":{"app":"Brave","id":3,"value":"https://youtube.com/watch?v=…"}}
    ← {"id":3,"result":{"ok":true,"diff":"~3     text field \"Address and search bar\" = https://youtube.com/watch?v=… [focused] {press}"}}
    → {"id":4,"method":"act","params":{"app":"Brave","id":3,"action":"press"}}
    ← {"id":4,"result":{"ok":true,"diff":"~1 standard window \"Loser - Audio playing - Brave\" {raise}"}}

Four calls. `raise` works across Spaces. Every action returns the diff of what
it did, so the model never spends a round-trip just to look.

The full protocol is in [docs/PROTOCOL.md](docs/PROTOCOL.md).

## Where the speed comes from

- **One IPC per element.** `AXUIElementCopyMultipleAttributeValues` fetches all
  ten attributes at once; action names are fetched only for interactive roles.
- **A messaging timeout** (1s) on every app element, so an unresponsive app can
  never hang the bridge.
- **Pruning.** Zero-size elements and their subtrees are dropped; untitled
  structural containers are hoisted so their children take their place —
  Chromium nests a dozen of these per control. `interactive:true` drops
  structural leaves too.
- **Diffs.** After the first snapshot of an app, `tree` returns only `~`
  changed, `+` added, and `- removed: 2-4, 9`. Matching is by stable id.
- **Stable ids, never reused.** `act 17` two turns later hits the same element
  or is refused — never a different one.

Measured timings against Brave with a dozen tabs, with and without `web:true`:
*pending — requires an Accessibility-trusted process; see below.*

## Permission

Every method except `hello` and `apps` needs Accessibility access for the
process that runs the bridge — a CLI inherits it from the app that launched it.
Without it, calls return `not_trusted` with the pane to open. The bundle is
ad-hoc signed with a stable identifier and a designated requirement on it, so a
rebuilt binary keeps its grant.

Web page content inside Chromium browsers is not in the tree unless asked for:
pass `"web":true` to set `AXEnhancedUserInterface`, which is what VoiceOver
does. It costs the browser measurable work per page, so it is opt-in.

## Layout

    Sources/AXModel/          pure: snapshot, ids, pruning, format, diff, protocol, dispatcher — all tested
    Sources/AXBridge/         the live adapter over AXUIElement and NSWorkspace — thin on purpose
    Sources/unbiased-ax/      the stdio server (a dozen lines)
    Sources/unbiased-ax-tests/ framework-free tests (CommandLineTools ships neither XCTest nor Swift Testing)
    docs/PROTOCOL.md          the wire protocol
    docs/INTEGRATION.md       how unbiased-app consumes this
    docs/plans/               the implementation plan this was built from
