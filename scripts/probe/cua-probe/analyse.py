#!/usr/bin/env python3
"""Read ~/cua-probe/probe.jsonl and say which mechanism the input arrived by.

The log has four independent witnesses to the same moment:

  native  what the target app received, and where the real pointer was then
  tap     what the rest of the system saw, from outside the app
  pointer the real pointer's trail, sampled every 10ms
  web     what a Chromium page received

Each hypothesis leaves a different combination, and this prints which one the
evidence actually matches rather than which one anyone expected.
"""
import json
import os
import sys
from collections import Counter
from datetime import datetime

PATH = sys.argv[1] if len(sys.argv) > 1 else os.path.expanduser("~/cua-probe/probe.jsonl")
MOUSE = {"mouseDown", "mouseUp", "mouseDragged", "rightMouseDown", "otherMouseDown", "scrollWheel"}
NEAR_MS = 400          # wall-clock slack when matching a tap row to an app row
SAME_SPOT = 6          # points, for "the pointer was already there"


def epoch_ms(row):
    """Rows come from three processes, each timing from its own start, so `t`
    is only comparable within one of them. The wall clock is the common one."""
    w = row.get("wall")
    if not w:
        return None
    try:
        return datetime.fromisoformat(w.replace("Z", "+00:00")).timestamp() * 1000
    except ValueError:
        return None


def load(path):
    rows = []
    with open(path) as fh:
        for line in fh:
            line = line.strip()
            if not line:
                continue
            try:
                rows.append(json.loads(line))
            except json.JSONDecodeError:
                pass
    return rows


def main():
    if not os.path.exists(PATH):
        print(f"no log at {PATH} — run ./start.sh first")
        return 1
    rows = load(PATH)
    if not rows:
        print(f"{PATH} is empty")
        return 1

    by_src = Counter(r.get("src", "?") for r in rows)
    launched = [r for r in rows if r.get("kind") in ("launched", "webLaunched", "recorderStarted")]
    native = [r for r in rows if r.get("src") == "native" and r.get("kind") in MOUSE]
    taps = [r for r in rows if r.get("src") == "tap"]
    ax = [r for r in rows if r.get("src") == "ax"]
    web = [r for r in rows if r.get("src") == "web" and r.get("type") in ("mousedown", "mouseup", "click", "pointerdown")]
    windows = [r for r in rows if r.get("src") == "window"]
    moves = [r for r in rows if r.get("src") == "pointer"]

    print(f"log {PATH}")
    print("rows by kind:", dict(by_src))
    for r in launched:
        print("  ", r.get("kind"), {k: v for k, v in r.items() if k in ("pid", "windowNumber", "bounds", "frameCG", "tap")})
    print()

    if windows:
        print("windows that appeared above ordinary windows (an overlay cursor would be one):")
        for w in windows:
            print(f"  +{w['t']:>7}ms  {w.get('owner')}  layer {w.get('layer')}  {w.get('bounds')}")
        print()

    if ax:
        print("ACCESSIBILITY actions (a press that never involved a pointer at all):")
        for a in ax:
            print(f"  +{a['t']:>7}ms  {a.get('kind')}  {a.get('label')}  pointer was at "
                  f"({a.get('systemPointerX')},{a.get('systemPointerY')})")
        print()

    if not native and not web and not ax:
        print("NOTHING reached either probe. The agent did not act on them, or it acted")
        print("somewhere this rig cannot see. Check the app names it was given.")
        return 0

    moved_to_click = 0
    stayed_away = 0
    seen_by_tap = 0
    unseen_by_tap = 0

    if native:
        print("NATIVE events the app received:")
        print(f"{'at':>9}  {'kind':<16} {'click(screen)':>15} {'pointer then':>15} {'gap':>6} "
              f"{'srcPid':>7} {'targetPid':>9}  active key")
        for e in native:
            cx, cy = e.get("screenCGX"), e.get("screenCGY")
            px, py = e.get("systemPointerX"), e.get("systemPointerY")
            gap = None
            if None not in (cx, cy, px, py):
                gap = int(((cx - px) ** 2 + (cy - py) ** 2) ** 0.5)
                if gap <= SAME_SPOT:
                    moved_to_click += 1
                else:
                    stayed_away += 1
            here = epoch_ms(e)
            match = [t for t in taps
                     if here is not None and epoch_ms(t) is not None and abs(epoch_ms(t) - here) <= NEAR_MS]
            if e.get("kind") in ("mouseDown", "mouseUp"):
                if match:
                    seen_by_tap += 1
                else:
                    unseen_by_tap += 1
            print(f"{e['t']:>7}ms  {e.get('kind'):<16} {f'({cx},{cy})':>15} {f'({px},{py})':>15} "
                  f"{str(gap):>6} {str(e.get('srcPid')):>7} {str(e.get('targetPid')):>9}  "
                  f"{str(e.get('appActive'))[:1]}      {str(e.get('windowIsKey'))[:1]}"
                  f"{'   [not in the system tap]' if e.get('kind') in ('mouseDown','mouseUp') and not match else ''}")
        print()

    if web:
        print("WEB events the Chromium page received:")
        for e in web[:40]:
            print(f"  +{e['t']:>7}ms  {e.get('type'):<12} at ({e.get('x')},{e.get('y')}) "
                  f"screen ({e.get('sx')},{e.get('sy')}) target {e.get('target')} trusted {e.get('trusted')}")
        if len(web) > 40:
            print(f"  … {len(web) - 40} more")
        print()

    if moves:
        span = f"{moves[0]['t']}ms to {moves[-1]['t']}ms"
        print(f"the real pointer moved {len(moves)} times ({span}); "
              f"first ({moves[0]['x']},{moves[0]['y']}) last ({moves[-1]['x']},{moves[-1]['y']})")
        print()

    print("=" * 72)
    print("WHAT THE EVIDENCE SAYS")
    print("=" * 72)
    if ax and not native:
        print("* Accessibility. The app was acted on without any mouse event at all,")
        print("  so no pointer was needed. This cannot place a point on a canvas.")
    if stayed_away and not moved_to_click:
        print("* Delivered WITHOUT moving the pointer. Every click arrived while the real")
        print("  pointer was somewhere else entirely. That is targeted delivery, not a")
        print("  pointer being borrowed.")
    if moved_to_click and not stayed_away:
        print("* The real pointer was MOVED to each click. Whatever is drawn on screen,")
        print("  the system pointer went there — the same thing our bridge does.")
    if moved_to_click and stayed_away:
        print(f"* Mixed: {moved_to_click} clicks with the pointer on the spot, {stayed_away} without.")
    if unseen_by_tap and not seen_by_tap:
        print("* Invisible to a system-wide event tap, so it never travelled the global")
        print("  event stream: posted to the process, or through a private route.")
    if seen_by_tap and not unseen_by_tap:
        print("* Seen by the system-wide tap, so it went through the global event stream")
        print("  like ordinary input.")
    if web and not native and not taps:
        print("* The Chromium page saw input the window and the system did not: the agent")
        print("  reached the renderer directly, not the app.")
    srcs = {e.get("srcPid") for e in native if e.get("srcPid")}
    if srcs:
        print(f"* Events name these source pids: {sorted(srcs)} — check which processes those are.")
    # targetPid is filled in by the system on delivery, so it says who received
    # the event, not how it was sent. It is printed above as information only.
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
