# cua-probe — how did that input actually arrive?

A rig for answering one question with evidence instead of impressions: when
another agent "clicks", what really happens? It records the same moment from
four independent places, and each explanation leaves a different combination.

| Explanation | app sees a mouse event | system-wide tap sees it | real pointer goes there |
|---|---|---|---|
| The pointer was borrowed (what our bridge does) | yes | yes | yes |
| Delivered to the process, pointer untouched | yes | no | no |
| An accessibility action, no pointer involved | no, an `ax` row instead | no | no |
| The browser engine was driven directly | only the web page sees it | no | no |
| Another client or session made the edit | nothing at all | no | no |

## Run it

```bash
./start.sh
```

That opens two windows and starts a recorder:

- **ProbeTarget** — a native Mac app. Buttons `TARGET-A`, `TARGET-B`,
  `TARGET-C`, a large `CANVAS` area, and a `TYPE-HERE` field. It records every
  mouse event it receives, every accessibility press, and where the real
  pointer was at that instant. Its window follows whichever Space is active
  and floats, so it stays reachable on a desktop of full-screen Spaces.
- **ProbeWeb** — the same targets on a Chromium surface, because the app we
  actually care about is one.
- **recorder** — a listen-only event tap plus a watch for new windows above
  the ordinary layer, which is where an overlay cursor would live.

Everything lands in `~/cua-probe/probe.jsonl`, one JSON object per line. The
previous run is kept alongside it with a timestamp.

## Then ask the other agent

Note where your pointer is, and **do not touch your mouse** while it works.
Give it tasks it cannot do any other way than by clicking:

- "In the app named ProbeTarget, click the button labelled TARGET-B."
- "In ProbeTarget, draw a zigzag in the CANVAS area by clicking about ten
  points across it."  ← the important one: a canvas cannot be pressed through
  accessibility, so this forces whatever its real click route is.
- "In ProbeTarget, type HELLO into the field labelled TYPE-HERE."
- "In the app named ProbeWeb, click the button labelled WEB-B."

Then:

```bash
./analyse.py
```

It prints every event with the pointer's position at that moment, whether the
system tap saw it, and a verdict.

## Reading it yourself

The decisive column is `gap`: the distance between where the click landed and
where the real pointer was at that instant.

- `gap` near zero means the pointer was moved to the click. There is no second
  pointer; whatever is drawn on screen, the system one went there.
- `gap` in the hundreds means the click arrived while the pointer was
  elsewhere. That is targeted delivery, and it is the thing worth copying.

`[not in the system tap]` on a row means the event never travelled the global
event stream, which rules out the ordinary route.

An `ACCESSIBILITY actions` section with no mouse rows means it never clicked at
all. That works for buttons and cannot work for a canvas.

A `windows that appeared` section names any overlay that showed up, which is
how a drawn agent cursor would register.

## Notes

- `./stop.sh` ends it. The log is kept.
- `./start.sh --no-web` skips the Chromium window.
- The recorder needs Accessibility permission for whatever runs it. If the tap
  cannot be created it says so in the log and on stdout rather than failing
  quietly.
- Nothing here modifies, consumes or delays any input. The tap is listen-only.

## slprobe — targeted delivery, measured

`build/slprobe` posts one mouse event straight at a process instead of through
the shared event stream, and reports what it took. It exists because an
earlier round of this work concluded that posting to a pid "never delivers"
mouse input. That was measured on a bare event. It was wrong.

```bash
build/slprobe --windows <pid>                       # window numbers to aim at
build/slprobe --cg --no-activate <pid> <wid> <screenX> <screenY> <winX> <winY>
build/slprobe --cg --drag <pid> <wid> <winOriginX> <winOriginY> x1,y1 x2,y2 …
```

Flags isolate one ingredient at a time: `--sl` posts only through
`SLEventPostToPid`, `--cg` only through the public `CGEventPostToPid`,
`--no-fields` drops the routing fields, omitting the window-local pair drops
the window location, `--no-activate` leaves focus alone and `--activate-only`
changes focus without posting.

### What the matrix says (2026-09-14, native AppKit target and Chromium)

| what was posted | Chromium received |
|---|---|
| routing fields + window location, either transport | **yes** |
| routing fields, no window location | no |
| window location, no routing fields | no |
| neither — a bare event posted to the pid | no |

Both ingredients are needed and neither alone is enough. The transport is not
one of the ingredients: the public `CGEventPostToPid` does it, and the private
`SLEventPostToPid` adds nothing. Posting through both delivers the event
twice.

The receiving app was not frontmost, its window was not key, the real pointer
was hundreds of points away and never moved, and no focus was changed.

A drag needs one thing more: `kCGMouseEventPressure` of 1 on the press and on
each dragged point, plus the button mask in field 45. Without them the dragged
points arrive as ordinary moves with no button held, and a canvas draws
nothing. With them the page reports `buttons: 1` throughout. Chromium still
coalesces the moves — about half of them at 20ms spacing — so this carries a
gesture from one place to another, not a faithful freehand stroke.

### Ingredients

1. `CGEventCreateMouseEvent`, HID-state source.
2. Fields: 1 click state, 2 pressure, 3 button, 7 subtype, **40 the target
   pid**, 45 button mask, **51 / 91 / 92 the window number**, 58 a click-group
   id shared by one gesture.
3. **`CGEventSetWindowLocation(event, localX, localY)`** — the window-local
   point. Private symbol; resolves today, so anything using it has to check
   first and have somewhere else to go.
4. `CGEventPostToPid(pid, event)`.

No activation, no `SLPSPostEventRecordTo`, no 248-byte record, no focus
change. Which means the hazard worth worrying about — a person typing an
email while the target is silently made active — does not arise here at all.

### Not yet measured

- The real target app, rather than a probe that was built to be easy to hit.
- A target on another Space, which is where this desktop keeps its apps.
- What a long path costs when half the moves are coalesced away.
