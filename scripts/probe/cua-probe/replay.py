#!/usr/bin/env python3
"""Replay one identical input sequence through both click routes, N times each.

The question this settles: does the quiet route — the one that delivers a click
at a coordinate the real pointer never visits — behave differently from an
ordinary click that moves the pointer there? An agent's own decisions change
between runs and drown that out, so nothing here decides anything: the same
coordinates, buttons and gaps go out every time, and the only variable is the
route.

Targets ProbeWeb, the Chromium probe, because Chromium is the engine the app we
care about runs on and it resets by relaunching. For every step it records what
was posted, what the page actually received, where the real pointer was, and
which app was frontmost, so a divergence can be pointed at rather than argued
about.

  ./replay.py                 # 5 runs each route, the default zigzag
  ./replay.py --runs 8
  ./replay.py --sequence my.json
"""
import argparse
import json
import os
import subprocess
import sys
import time

HERE = os.path.dirname(os.path.abspath(__file__))
BRIDGE = os.path.abspath(os.path.join(HERE, "..", "..", "..", "dist", "unbiased-ax"))
LOG = os.path.expanduser("~/cua-probe/probe.jsonl")

# A canvas zigzag: the shape of the workflow that stalls, in fractions of the
# window. Deliberately boring and fixed.
DEFAULT_SEQUENCE = [{"x": 0.12 + i * 0.08, "y": 0.30 + (0.22 if i % 2 else 0.0)} for i in range(10)]


def bridge(requests, quiet):
    """Run one conversation with the bridge, with the route forced either way."""
    env = dict(os.environ, UNBIASED_AX_QUIET_POINTER="1" if quiet else "0")
    p = subprocess.Popen([BRIDGE], stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                         stderr=subprocess.DEVNULL, text=True, env=env, bufsize=1)
    out = []
    for r in requests:
        p.stdin.write(json.dumps(r) + "\n")
        p.stdin.flush()
        line = p.stdout.readline()
        try:
            out.append(json.loads(line))
        except json.JSONDecodeError:
            out.append({"error": {"message": line.strip()}})
        time.sleep(0.3)
    p.stdin.close()
    p.wait(timeout=5)
    return out


def log_tail(since):
    rows = []
    with open(LOG) as fh:
        for line in fh:
            line = line.strip()
            if not line:
                continue
            try:
                r = json.loads(line)
            except json.JSONDecodeError:
                continue
            if r.get("wall", "") >= since:
                rows.append(r)
    return rows


def find_window(prefer):
    """The app to aim at: whichever of the probes the bridge can actually see."""
    res = bridge([{"id": 1, "method": "apps", "params": {}}], quiet=True)
    apps = (res[0].get("result") or {}).get("apps", [])
    names = [a.get("name") for a in apps]
    if prefer in names:
        return prefer
    for wanted in ("Electron", "ProbeTarget"):
        if wanted in names:
            return wanted
    return None


def one_run(app, sequence, quiet):
    since = time.strftime("%Y-%m-%dT%H:%M:%S", time.gmtime())
    reqs = [
        {"id": 1, "method": "tree", "params": {"app": app}},
        {"id": 2, "method": "pointer", "params": {"app": app, "id": 2, "path": sequence}},
    ]
    out = bridge(reqs, quiet)
    time.sleep(1.2)
    rows = log_tail(since)
    # Whichever probe answered: the Chromium page or the native window.
    web = [r for r in rows if r.get("src") == "web" and r.get("type") == "mousedown"]
    if not web:
        web = [{"sx": r.get("screenCGX"), "sy": r.get("screenCGY")}
               for r in rows if r.get("src") == "native" and r.get("kind") == "mouseDown"]
    res = out[-1].get("result") or out[-1].get("error") or {}
    return {
        "posted": len(sequence),
        "bridgeSaid": len(res.get("at") or []) if "at" in res else 0,
        "error": res.get("message"),
        "pageReceived": len(web),
        "pagePoints": [(w.get("sx"), w.get("sy")) for w in web],
        "pointerUntouched": res.get("pointerUntouched"),
    }


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--runs", type=int, default=5)
    ap.add_argument("--sequence")
    ap.add_argument("--app", default="Electron", help="Electron = the Chromium probe, ProbeTarget = the native one")
    args = ap.parse_args()
    sequence = json.load(open(args.sequence)) if args.sequence else DEFAULT_SEQUENCE

    if not os.path.exists(BRIDGE):
        print(f"no bridge at {BRIDGE} — run `make bundle` in the repo root")
        return 1
    app = find_window(args.app)
    if not app:
        print("neither probe is visible to the bridge — start them with ./start.sh")
        return 1

    print(f"target {app}, {len(sequence)} points, {args.runs} runs each route\n")
    results = {}
    for quiet in (True, False):
        name = "quiet (pointer never moves)" if quiet else "ordinary (pointer moves)"
        rows = []
        for i in range(args.runs):
            r = one_run(app, sequence, quiet)
            rows.append(r)
            mark = "ok " if r["pageReceived"] == r["posted"] else "DIFF"
            print(f"  {name:<30} run {i + 1}: {mark} posted {r['posted']}, "
                  f"page got {r['pageReceived']}"
                  f"{', error: ' + r['error'] if r.get('error') else ''}")
        results[name] = rows
        print()

    print("=" * 68)
    for name, rows in results.items():
        got = [r["pageReceived"] for r in rows]
        full = sum(1 for r in rows if r["pageReceived"] == r["posted"])
        print(f"{name}: {full}/{len(rows)} runs delivered every point; counts {got}")
    print("=" * 68)
    print("A route that drops points, or drops them at a different step each time,")
    print("is the one to stop using for canvas work.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
