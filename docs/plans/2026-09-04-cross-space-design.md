# Cross-Space windows: read and act on an app the user is not looking at

Design, validated 2026-09-04 against real Brave, Chrome, Notes, ChatGPT and
Finder on macOS 26 (Darwin 25.6). Every number below was measured that day;
the probes that produced them are in `scripts/probe/`.

## The problem

The user runs one fullscreen app per Space and switches Spaces constantly.
Unbiased lives on one Space; the app the agent is driving lives on another.

`AXWindows` on an application element lists only the windows on the **current
Space**. From Unbiased's Space, Brave has no windows. So the bridge's answer
was `raise`: activate the app, let macOS switch Spaces, then read. unbiased-app
then built two layers of recovery on top — `reassertRaise` after every approval
card, and `shouldRecoverRaise` inside every read — because the card, and the
user going back to Unbiased, kept undoing the raise.

Measured on the Maps task, 2026-09-04 17:55–17:59 UTC (`/tmp/unbiased-ax-diag.log`):
**10 raises in four minutes, 9 of them automatic**, every one logged as
`read found 0 windows here, 6 offscreen`. The loop was the user versus the
recovery: each return to Unbiased made the next read find nothing and switch
back.

Codex's trace over the same task (12:16 the same day) never raised. Its
primitives are ours — set value, press key, click — and ours already work on a
background app. The only wall was the Space.

## What we found

The Space limit lives in the `AXWindows` *enumeration*, not in element access.
Once the bridge holds an `AXUIElement` for a window, the AX server answers
regardless of which Space the window is on.

Three private symbols in HIServices make that reachable:

| symbol | what it does |
|---|---|
| `_AXUIElementCreateWithRemoteToken(CFData) -> AXUIElement?` | builds an element from a token |
| `_AXUIElementRemoteTokenCreate(AXUIElement) -> CFData?` | the token of an existing element |
| `_AXUIElementGetWindow(AXUIElement, *CGWindowID) -> AXError` | the window-server id behind a window element |

The token for a window element is 20 bytes, little-endian:

    bytes 0-3   pid
    bytes 4-7   0
    bytes 8-11  0x636f636f   ('coco')
    bytes 12-15 the app's INTERNAL AX element id — not the CGWindowID
    bytes 16-19 0

The application element's token is 12 bytes: pid, 0, `0x61707020` (`'app '`).

The element id is a per-process handle the app's AX server allocates as it
creates elements. It cannot be derived from a window id, so the mechanism is a
**scan**: try element ids from 0 upward, keep the ones whose role is
`AXWindow`, and map each to its window with `_AXUIElementGetWindow`. A miss is a
fast `-25202 kAXErrorInvalidUIElement`. This is exactly what AltTab ships as
`windowsByBruteForce`; yabai uses the same symbols.

Element ids are allocated when a window is first **vended** to an AX client, not
when it is created. Measured 2026-09-04 with a Calculator launched by `open -g`:
its one window had no element until `AXMainWindow` was read on the app root
(`AXWindows`, which lists nothing off-screen, vends nothing); one read later the
scan found it as element 42. So the scan is preceded by reading `AXMainWindow`
and `AXFocusedWindow`, and a map that holds no real window settles nothing.

Measured:

| what | result |
|---|---|
| scan 3000 element ids (Brave) | 48 ms — about 16 µs per miss |
| window element ids observed | 45–55, 181, 209 — allocated early, small; Chrome's window 104 was element 209 |
| Brave's fullscreen window, off-Space, walked | 477 elements in 31 ms, including an `AXWebArea` with 302 elements under it |
| Notes (Cocoa), off-Space, walked | 156 elements in 54 ms |
| element rebuilt from a from-scratch token vs the public `AXWindows` element | `CFEqual` true, `CFHash` equal, same window id |
| set `AXFocused=true` on Brave's address bar, off-Space | `AXError 0` in 3 ms; read-back true; frontmost app, on-screen windows and Brave's on-screen state all unchanged |

The identity result is what makes this safe for the rest of the bridge: the
element reached by scan *is* the element `AXWindows` returns when the window is
on-Space, so `IdRegistry` keeps the same id across Space switches.

Two things `CGWindowListCopyWindowInfo` taught us along the way. Every app owns
four 3840×30 layer-0 windows with no AX element behind them — system strips,
not windows — and a fullscreen browser owns extra full-width panes (Brave:
3840×75 and 3840×40) whose AX elements are `AXWindow` with subrole `AXUnknown`
and one element each. Brave's "9 windows" is one standard window. The bridge's
`offscreen` count has been wrong by that factor since it shipped.

## Design

### 1. Architecture

**A `WindowMap` per pid, inside `LiveBackend`.** `wid → AXElement` for every
window the window server lists for the process. Populated by scanning element
ids, keeping `AXWindow` hits, mapping each with `_AXUIElementGetWindow`. It is
a cache:

- Rescan only when `CGWindowListCopyWindowInfo` shows a layer-0 wid for the pid
  that is not mapped. Drop entries whose wid has gone.
- Stop the scan as soon as every unmapped wid is found. Hard cap on the range
  (65,536 ids is about a second at the measured rate) so a wid that has no AX
  element cannot make us scan forever.
- Remember wids that mapped to nothing until they disappear — but only once at
  least one real window is mapped, so a fresh launch keeps looking until its
  window is vended. The system strips then cost one scan per app.
- Ids are not resumed from the highest seen: that could not skip the strips'
  to-cap scan and would be unsafe if an app recycled ids.

**Two plug-in points.** `LiveSource.children(of: appRoot)` already unions
`AXChildren` with `AXWindows`; it gains the map's elements as a third source,
deduplicated by `CFEqual`. `LiveBackend.windows(app:)` iterates the same map.
`IdRegistry`, `Snapshot`, `Differ` and every action verb are untouched — they
work on elements and always did.

**Which windows count.** Subrole `AXStandardWindow` or `AXDialog`, the AltTab
filter. Fullscreen toolbar panes and system strips are excluded from both the
`windows` listing and the tree roots; the address bar was found inside the
standard window on a real fullscreen Brave.

**Self-check, then fallback.** The verdict is lazy: decided on the first
trusted call (`hello`, in practice), not at `LiveBackend` init, because the app
spawns the bridge before the user may have granted Accessibility. `dlsym` the
three symbols, then prove the mechanism on this machine: an app with a public
`AXWindows` window that has a window id is a witness — the token round-trip
must be `CFEqual` and a scan must then map at least one real window; without
one, any regular app whose scan maps a real window is accepted. Three
outcomes: true; nil — undecided (not trusted, or nothing to witness with),
asked again at most every 30 s; and a definitive false only for missing symbols
or no witness round-tripping, which leaves the bridge behaving exactly as it
does today. `hello` reports the flag. The rule: never act on a private API that
has stopped round-tripping on this machine.

`AXModel` stays pure. Nothing in this section touches it.

### 2. What the model sees

The principle: **the model never thinks about Spaces.**

- `windows` lists every real window wherever it lives, with a new per-window
  `onSpace` flag (membership in the public `AXWindows`). `offscreen` becomes
  "real windows not on this Space" — honest for the first time.
- `tree`, `find` and every action work on off-Space windows like any other.
  The "call raise for this app first" hint is gone when `crossSpace` is on;
  the existing three-state hint text is unchanged when it is off.
- `raise` keeps its mechanics and narrows its meaning: bring an app forward
  because the user should see it, never as a prerequisite for reading.
- `launch` opens in the background (`open -g`). Its wait loop changes from
  "a window on THIS Space" to "a window in the map". The short-circuit stays:
  an app that already has a real window is returned without touching focus.
- `hello` gains `crossSpace: Bool`.
- `protocolVersion` stays 1; everything is additive. `docs/PROTOCOL.md` is
  updated for `onSpace`, `crossSpace`, `launch`, `scroll`, and the three stale
  entries found on 2026-09-04 (`keepFront` default, the off-Space "still work"
  claim, missing methods).

### 3. The app side

In unbiased-app (the `fix/ax-launch-scroll-verbs` worktree the dev build runs
from):

- `shouldRecoverRaise`, `reassertRaise` and `axRaised` are gated on
  `!crossSpace`. They stay so the fallback path is today's behavior, not a
  third state.
- `computer_app_state`'s description drops the "call computer_raise once, then
  read again" sentence. `computer_raise`'s description becomes: bring an app
  forward only when the user should see it. `axNeedsFocus` is unchanged —
  raising still takes the screen and still needs a card.
- Nothing else. `launch`, `do`, `computer_act` call bridge verbs whose shapes
  do not change.

### 4. Testing

The repo's split stands: the pure layer is unit-tested, the bridge is verified
by hand and by a runtime self-check.

- **AXModel.** `FakeBackend` gets a `crossSpace` knob. With it on, a read of an
  app with zero windows here and one elsewhere carries no hint and reports
  `offscreen: 1`; with it off, the current hint text is byte-identical.
  `WindowInfo.onSpace` renders in the window line. `hello` carries the flag.
  `launch` still returns the tree.
- **AXBridge.** The startup self-check is the runtime test. `scripts/probe/`
  holds the four read-only probes from 2026-09-04 (`remote-token`, `brute`,
  `identity`, `webwalk`) plus the approved `focus` action probe; they print the
  same evidence as the table above and are the manual verification recipe.
- **unbiased-app.** `ax-bridge.test.ts`: the recovery helpers are not consulted
  when `crossSpace` is on; the description text is asserted.
- **Acceptance, measured.** Rerun the Maps task from the diagnostic log with
  `UNBIASED_AX_DEBUG=1`, from Unbiased's Space, and count raises. Today 10.
  Target 0. Same for the README's YouTube-in-Brave task.

## Risks

- **Private API.** The token layout and the three symbols are observed, not
  contractual. Mitigated by the self-check and fallback; a macOS update that
  breaks the trick degrades to today, silently.
- **`scroll` off-Space is unverified.** It is the one verb that uses screen
  coordinates: it posts a `mouseMoved` at the element's midpoint before the
  wheel event. An off-Space window's coordinates are in that Space's frame.
  The plan must verify it on a real off-Space window before the verb is
  declared cross-Space-safe; `key` (pid-posted, no coordinates) is expected to
  work and should be verified the same way.
- **Chromium for non-visible windows.** Measured fine today (the web area was
  fully populated off-Space), but Chromium's renderer throttling is not under
  our control.
- **Scan cost for late windows.** A window opened after a long Chromium
  session has a high element id. The cap bounds the cost to about a second,
  once per app that has a real window, and once per second for one that does
  not.
- **A second window first vended after the map settled** stays unmapped until
  the next scan for any reason (a new wid, or the empty-map retry): the wake
  reads only the main and focused windows. Not seen on the measured apps
  (every existing window had been shown, hence vended); recorded so nobody
  chases it as a scan bug.

## Found along the way, out of scope

- `AXIdentifier`, `AXPlaceholder` and `AXHelp` are in Codex's trace and not in
  ours. All three fit in the existing single-IPC batch fetch. `AXIdentifier`
  (`MapsSearchTextField`, `ActionRowItemTypeDirections`) is a far better `find`
  target than title substrings.
- `Dispatcher.last` is keyed by the raw app string while `LiveBackend` keys by
  pid: `tree "Brave"` then `act "Brave Browser"` is refused.
- `snapshot()` replaces `elements[pid]` wholesale, invalidating window ids from
  a prior `windows` call; `raise(windowId:)` then fails on off-Space windows.
- `posRef as! AXValue?` in `scroll` can trap the process on a non-`AXValue`.
- `AXUIElementSetAttributeValue(root, "AXEnhancedUserInterface")` returns
  `-25208` on Brave and the return is ignored; the attribute was already on.
