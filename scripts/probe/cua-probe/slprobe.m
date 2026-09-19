// slprobe — post one mouse event the way a targeted driver does, and say what
// it took to get there.
//
// The bridge's own experiments rejected CGEventPostToPid for mouse input, but
// they posted a bare event: no target pid on it, no window number, no window
// location, no activation, no move before the press. This posts the stamped
// version instead, so the question "does targeted delivery work at all" is
// asked properly. It changes nothing in the bridge; it only measures.
//
//   slprobe <pid> <windowNumber> <screenX> <screenY> [winX winY]
//   slprobe --no-activate …   post without touching focus
//   slprobe --activate-only … focus without posting, to time the focus window
#import <Cocoa/Cocoa.h>
#include <dlfcn.h>

typedef void (*PostToPidFn)(pid_t, void *);
typedef int  (*PostRecordFn)(const void *, const uint8_t *);
typedef int  (*PsnFn)(void *);
typedef int  (*ProcForPidFn)(pid_t, void *);
typedef int  (*WindowOwnerFn)(int, uint32_t, uint32_t *);
typedef int  (*ConnPsnFn)(uint32_t, void *);
typedef int  (*MainConnFn)(void);
typedef void (*SetWinLocFn)(void *, double, double);

static void *S(const char *n) { return dlsym(RTLD_DEFAULT, n); }
static void cuaClick(pid_t pid, uint32_t wid, CGPoint at, double lx, double ly);
static void cuaDrag(pid_t pid, uint32_t wid, CGPoint a, double alx, double aly, CGPoint b, double blx, double bly);
extern BOOL gPressureFwd;
static BOOL activateWithoutRaise(pid_t pid, uint32_t wid);

static int gTransport = 0;   // 0 both, 1 SLEventPostToPid only, 2 CGEventPostToPid only
static BOOL gStampFields = YES;
static BOOL gRestore = NO;
static BOOL gCua = NO;
static BOOL gSkipActivate = NO;
static BOOL gPressure;


static NSString *frontName(void) {
  NSRunningApplication *a = NSWorkspace.sharedWorkspace.frontmostApplication;
  return a ? [NSString stringWithFormat:@"%@ (%d)", a.localizedName, a.processIdentifier] : @"(none)";
}

// The target's PSN: by the window's owning connection when that resolves,
// else by pid. Only the PSN addresses a process for these calls.
static BOOL psnForWindow(uint32_t wid, pid_t pid, uint8_t psn[8]) {
  MainConnFn mainConn = (MainConnFn)S("SLSMainConnectionID");
  WindowOwnerFn owner = (WindowOwnerFn)S("SLSGetWindowOwner");
  ConnPsnFn connPsn = (ConnPsnFn)S("SLSGetConnectionPSN");
  if (mainConn && owner && connPsn && wid) {
    uint32_t ownerCid = 0;
    if (owner(mainConn(), wid, &ownerCid) == 0 && ownerCid != 0 && connPsn(ownerCid, psn) == 0) return YES;
  }
  ProcForPidFn forPid = (ProcForPidFn)S("GetProcessForPID");
  return forPid && forPid(pid, psn) == 0;
}

// Make the target internally active without raising its window: one record
// telling the current front it has lost focus, one telling the target it has
// gained it. Note what is NOT here — nothing puts the first one back.
static BOOL activateWithoutRaise(pid_t pid, uint32_t wid) {
  PostRecordFn post = (PostRecordFn)S("SLPSPostEventRecordTo");
  PsnFn getFront = (PsnFn)S("_SLPSGetFrontProcess") ?: (PsnFn)S("SLPSGetFrontProcess");
  if (!post || !getFront) { printf("  activate: symbols missing\n"); return NO; }
  uint8_t prev[8] = {0}, target[8] = {0};
  if (getFront(prev) != 0) { printf("  activate: no front process\n"); return NO; }
  if (!psnForWindow(wid, pid, target)) { printf("  activate: no PSN for the target\n"); return NO; }
  uint8_t buf[0xF8] = {0};
  buf[0x04] = 0xF8;
  buf[0x08] = 0x0D;
  buf[0x3C] = wid & 0xFF; buf[0x3D] = (wid >> 8) & 0xFF;
  buf[0x3E] = (wid >> 16) & 0xFF; buf[0x3F] = (wid >> 24) & 0xFF;
  buf[0x8A] = 0x02; int defocus = post(prev, buf);
  buf[0x8A] = 0x01; int focus = post(target, buf);
  uint8_t after[8] = {0};
  getFront(after);
  printf("  activate: defocus=%d focus=%d\n", defocus, focus);
  printf("  PSN front before %02x%02x%02x%02x%02x%02x%02x%02x  target %02x%02x%02x%02x%02x%02x%02x%02x  front after %02x%02x%02x%02x%02x%02x%02x%02x\n",
    prev[0],prev[1],prev[2],prev[3],prev[4],prev[5],prev[6],prev[7],
    target[0],target[1],target[2],target[3],target[4],target[5],target[6],target[7],
    after[0],after[1],after[2],after[3],after[4],after[5],after[6],after[7]);
  printf("  WindowServer front changed to target: %s\n", memcmp(after, target, 8) == 0 ? "YES" : "no");
  return defocus == 0 && focus == 0;
}

static void stamp(CGEventRef e, pid_t pid, uint32_t wid, int64_t clickState, int64_t group, BOOL hasWin, double wx, double wy) {
  CGEventSetIntegerValueField(e, kCGMouseEventClickState, clickState);
  // A press and a drag carry full pressure; nothing else does. Without it the
  // receiver asks the system which buttons are down, and the system says none.
  CGEventType ty = CGEventGetType(e);
  BOOL held = (ty == kCGEventLeftMouseDown || ty == kCGEventLeftMouseDragged);
  CGEventSetDoubleValueField(e, kCGMouseEventPressure, held ? 1.0 : 0.0);
  if (held) CGEventSetIntegerValueField(e, (CGEventField)45, 1);   // button mask: left held
  CGEventSetIntegerValueField(e, kCGMouseEventButtonNumber, 0);
  CGEventSetIntegerValueField(e, kCGMouseEventSubtype, 3);
  if (gStampFields) {
  CGEventSetIntegerValueField(e, (CGEventField)40, pid);       // the Chromium filter
  CGEventSetIntegerValueField(e, (CGEventField)58, group);     // one gesture
  if (wid) {
    CGEventSetIntegerValueField(e, (CGEventField)51, wid);     // windowNumber
    CGEventSetIntegerValueField(e, (CGEventField)91, wid);     // window under the pointer
    CGEventSetIntegerValueField(e, (CGEventField)92, wid);     // window that can handle it
  }
  }
  SetWinLocFn setWinLoc = (SetWinLocFn)S("CGEventSetWindowLocation");
  if (hasWin && setWinLoc) setWinLoc((void *)e, wx, wy);
}

static void postBoth(CGEventRef e, pid_t pid) {
  PostToPidFn sl = (PostToPidFn)S("SLEventPostToPid");
  if (gTransport != 2 && sl) sl(pid, (void *)e);
  if (gTransport != 1) CGEventPostToPid(pid, e);
}

// Every window a pid owns, so a target can be named without guessing.
static void listWindows(pid_t pid) {
  CFArrayRef all = CGWindowListCopyWindowInfo(kCGWindowListOptionAll | kCGWindowListExcludeDesktopElements, kCGNullWindowID);
  for (CFIndex i = 0; i < CFArrayGetCount(all); i++) {
    NSDictionary *w = (__bridge NSDictionary *)CFArrayGetValueAtIndex(all, i);
    if ([w[(id)kCGWindowOwnerPID] intValue] != pid) continue;
    CGRect r = CGRectZero;
    CGRectMakeWithDictionaryRepresentation((__bridge CFDictionaryRef)w[(id)kCGWindowBounds], &r);
    printf("  wid %-8d %-28s %.0f,%.0f %.0fx%.0f\n", [w[(id)kCGWindowNumber] intValue],
           [[NSString stringWithFormat:@"%@", w[(id)kCGWindowOwnerName]] UTF8String], r.origin.x, r.origin.y, r.size.width, r.size.height);
  }
  CFRelease(all);
}

// A held path: move, press, drag through each point, release. Window-local
// coordinates come from the window origin, so a path is written in screen
// points like any other.
static int runPath(pid_t pid, uint32_t wid, CGPoint origin, NSArray<NSValue *> *pts, BOOL held) {
  CGEventSourceRef src = CGEventSourceCreate(kCGEventSourceStateHIDSystemState);
  int64_t group = (int64_t)(CFAbsoluteTimeGetCurrent() * 1e6);
  CGPoint first = pts.firstObject.pointValue;
  #define SEND(type, pt, state) do { \
    CGEventRef e = CGEventCreateMouseEvent(src, type, pt, kCGMouseButtonLeft); \
    stamp(e, pid, wid, state, group, YES, pt.x - origin.x, pt.y - origin.y); \
    postBoth(e, pid); CFRelease(e); } while (0)
  SEND(kCGEventMouseMoved, first, 0);
  usleep(12000);
  SEND(kCGEventLeftMouseDown, first, 1);
  usleep(12000);
  for (NSUInteger k = 1; k < pts.count; k++) {
    CGPoint pt = pts[k].pointValue;
    SEND(held ? kCGEventLeftMouseDragged : kCGEventMouseMoved, pt, held ? 1 : 0);
    usleep(20000);
  }
  SEND(kCGEventLeftMouseUp, pts.lastObject.pointValue, 1);
  #undef SEND
  if (src) CFRelease(src);
  return 0;
}

int main(int argc, const char *argv[]) { @autoreleasepool {
  BOOL noActivate = NO, activateOnly = NO;
  int i = 1;
  for (; i < argc && strncmp(argv[i], "--", 2) == 0; i++) {
    if (!strcmp(argv[i], "--no-activate")) noActivate = YES;
    else if (!strcmp(argv[i], "--activate-only")) activateOnly = YES;
    else if (!strcmp(argv[i], "--sl")) gTransport = 1;
    else if (!strcmp(argv[i], "--cg")) gTransport = 2;
    else if (!strcmp(argv[i], "--no-fields")) gStampFields = NO;
    else if (!strcmp(argv[i], "--restore")) gRestore = YES;
    else if (!strcmp(argv[i], "--cua")) gCua = YES;
    else if (!strcmp(argv[i], "--pressure")) gPressure = YES;
    else if (!strcmp(argv[i], "--skip-activate")) gSkipActivate = YES;
    else if (!strcmp(argv[i], "--cua-drag")) {
      pid_t tp = atoi(argv[i+1]); uint32_t tw = (uint32_t)strtoul(argv[i+2], NULL, 10);
      CGPoint a = CGPointMake(atof(argv[i+3]), atof(argv[i+4]));
      double alx = atof(argv[i+5]), aly = atof(argv[i+6]);
      CGPoint b = CGPointMake(atof(argv[i+7]), atof(argv[i+8]));
      double blx = atof(argv[i+9]), bly = atof(argv[i+10]);
      CGPoint h = CGEventGetLocation(CGEventCreate(NULL));
      printf("drag (%.0f,%.0f)->(%.0f,%.0f), front %s, pointer (%.0f,%.0f)\n",
             a.x, a.y, b.x, b.y, frontName().UTF8String, h.x, h.y);
      cuaDrag(tp, tw, a, alx, aly, b, blx, bly);
      usleep(200000);
      CGPoint n = CGEventGetLocation(CGEventCreate(NULL));
      printf("  after: front %s, pointer (%.0f,%.0f) — moved %s\n", frontName().UTF8String, n.x, n.y,
             (fabs(n.x-h.x) < 2 && fabs(n.y-h.y) < 2) ? "NO" : "YES");
      return 0;
    }
    else if (!strcmp(argv[i], "--windows")) { listWindows(atoi(argv[i+1])); return 0; }
    else if (!strcmp(argv[i], "--path") || !strcmp(argv[i], "--drag")) {
      BOOL held = !strcmp(argv[i], "--drag");
      pid_t tp = atoi(argv[i+1]); uint32_t tw = (uint32_t)strtoul(argv[i+2], NULL, 10);
      CGPoint org = CGPointMake(atof(argv[i+3]), atof(argv[i+4]));
      NSMutableArray *pts = [NSMutableArray array];
      for (int k = i + 5; k < argc; k++) { double x, y; if (sscanf(argv[k], "%lf,%lf", &x, &y) == 2) [pts addObject:[NSValue valueWithPoint:NSMakePoint(x, y)]]; }
      CGPoint h = CGEventGetLocation(CGEventCreate(NULL));
      printf("%s %lu point(s), front %s, pointer (%.0f,%.0f)\n", held ? "drag" : "path", (unsigned long)pts.count, frontName().UTF8String, h.x, h.y);
      runPath(tp, tw, org, pts, held);
      usleep(150000);
      CGPoint n = CGEventGetLocation(CGEventCreate(NULL));
      printf("  after: front %s, pointer (%.0f,%.0f) — moved %s\n", frontName().UTF8String, n.x, n.y,
             (fabs(n.x - h.x) < 2 && fabs(n.y - h.y) < 2) ? "NO" : "YES");
      return 0;
    }
  }
  if (argc - i < 4) { printf("usage: slprobe [--no-activate|--activate-only] <pid> <wid> <x> <y> [winX winY]\n"); return 2; }
  pid_t pid = atoi(argv[i]);
  uint32_t wid = (uint32_t)strtoul(argv[i+1], NULL, 10);
  CGPoint at = CGPointMake(atof(argv[i+2]), atof(argv[i+3]));
  BOOL hasWin = (argc - i >= 6);
  double wx = hasWin ? atof(argv[i+4]) : 0, wy = hasWin ? atof(argv[i+5]) : 0;

  NSRunningApplication *prevApp = NSWorkspace.sharedWorkspace.frontmostApplication;
  CGPoint home = CGEventGetLocation(CGEventCreate(NULL));
  printf("pid %d wid %u at (%.0f,%.0f)%s\n", pid, wid, at.x, at.y, hasWin ? " window-local set" : "");
  printf("  front before: %s   pointer at (%.0f,%.0f)\n", frontName().UTF8String, home.x, home.y);

  if (!noActivate && !gCua) { activateWithoutRaise(pid, wid); usleep(50000); }
  printf("  front after activate: %s\n", frontName().UTF8String);
  if (activateOnly) return 0;

  if (gCua) { cuaClick(pid, wid, at, wx, wy); goto after; }
  CGEventSourceRef src = CGEventSourceCreate(kCGEventSourceStateHIDSystemState);
  int64_t group = (int64_t)(CFAbsoluteTimeGetCurrent() * 1e6);
  CGEventRef moved = CGEventCreateMouseEvent(src, kCGEventMouseMoved, at, kCGMouseButtonLeft);
  stamp(moved, pid, wid, 0, group, hasWin, wx, wy); postBoth(moved, pid); CFRelease(moved);
  usleep(12000);
  CGEventRef down = CGEventCreateMouseEvent(src, kCGEventLeftMouseDown, at, kCGMouseButtonLeft);
  stamp(down, pid, wid, 1, group, hasWin, wx, wy); postBoth(down, pid); CFRelease(down);
  usleep(28000);
  CGEventRef up = CGEventCreateMouseEvent(src, kCGEventLeftMouseUp, at, kCGMouseButtonLeft);
  stamp(up, pid, wid, 1, group, hasWin, wx, wy); postBoth(up, pid); CFRelease(up);
  if (src) CFRelease(src);

after:
  usleep(120000);
  if (gRestore && prevApp && NSWorkspace.sharedWorkspace.frontmostApplication.processIdentifier != prevApp.processIdentifier) {
    [prevApp activateWithOptions:0];
    usleep(250000);
    printf("  restored front to %s\n", prevApp.localizedName.UTF8String);
  }
  CGPoint now = CGEventGetLocation(CGEventCreate(NULL));
  if (!gCua) printf("  posted move+down+up (both transports)\n");
  printf("  front after: %s   pointer now (%.0f,%.0f) — moved %s\n",
         frontName().UTF8String, now.x, now.y,
         (fabs(now.x - home.x) < 2 && fabs(now.y - home.y) < 2) ? "NO" : "YES");
  return 0;
} }

// ── The documented background-click sequence, replicated exactly ────────────
// Transcribed from cua-driver (MIT, Copyright (c) 2025 Cua AI, Inc.),
// crates/platform-macos/src/input/mouse.rs `click_at_xy_chromium`. Replicated
// here rather than linked, so the mechanism can be measured against this
// bridge's own routes on one machine.
//
// The pieces this probe was missing before: field 0 carries a gesture PHASE,
// not a number; a primer press lands off-screen at (-1,-1) first, where it can
// reach no element but still satisfies the receiver's user-activation gate;
// a frame of quiet separates primer from target so the two are not read as one
// run-on gesture; and the whole thing goes through the private poster, with the
// public one only as a fallback.

typedef void (*SetIntFieldFn)(void *, uint32_t, int64_t);

static void cuaField(CGEventRef e, uint32_t field, int64_t value) {
  static SetIntFieldFn slSet = NULL;
  static dispatch_once_t once;
  dispatch_once(&once, ^{ slSet = (SetIntFieldFn)S("SLEventSetIntegerValueField"); });
  if (slSet) slSet((void *)e, field, value);
  else CGEventSetIntegerValueField(e, (CGEventField)field, value);
}

static void cuaPost(CGEventRef e, pid_t pid) {
  PostToPidFn sl = (PostToPidFn)S("SLEventPostToPid");
  if (sl) sl(pid, (void *)e);
  else CGEventPostToPid(pid, e);
}

/// One event of the sequence. `phase` is field 0: 1 primer-down, 2 a move or
/// primer-up, 3 the target press and release.
static void cuaSend(CGEventSourceRef src, CGEventType type, CGPoint at, double lx, double ly,
                    pid_t pid, uint32_t wid, int64_t clickState, int64_t phase, int64_t group) {
  CGEventRef e = CGEventCreateMouseEvent(src, type, at, kCGMouseButtonLeft);
  if (!e) return;
  cuaField(e, 0, phase);
  cuaField(e, 1, clickState);
  cuaField(e, 3, 0);
  cuaField(e, 7, 3);
  cuaField(e, 40, pid);
  if (wid) { cuaField(e, 51, wid); cuaField(e, 91, wid); cuaField(e, 92, wid); }
  cuaField(e, 58, group);
  SetWinLocFn setWinLoc = (SetWinLocFn)S("CGEventSetWindowLocation");
  if (setWinLoc) setWinLoc((void *)e, lx, ly);
  cuaPost(e, pid);
  CFRelease(e);
}

static void cuaClick(pid_t pid, uint32_t wid, CGPoint at, double lx, double ly) {
  printf("  %s, move, off-screen primer, target\n", gSkipActivate ? "NO activate" : "activate");
  if (!gSkipActivate) { activateWithoutRaise(pid, wid); usleep(50000); }                                   // AppKit settles its routing
  CGEventSourceRef src = CGEventSourceCreate(kCGEventSourceStateHIDSystemState);
  int64_t group = (int64_t)(CFAbsoluteTimeGetCurrent() * 1e6);   // one gesture
  CGPoint off = CGPointMake(-1, -1);
  cuaSend(src, kCGEventMouseMoved,    at,  lx,  ly, pid, wid, 0, 2, group);
  usleep(15000);
  cuaSend(src, kCGEventLeftMouseDown, off, -1, -1, pid, wid, 1, 1, group);
  usleep(1000);
  cuaSend(src, kCGEventLeftMouseUp,   off, -1, -1, pid, wid, 1, 2, group);
  usleep(100000);                                  // a frame, so it is not run-on
  cuaSend(src, kCGEventLeftMouseDown, at,  lx,  ly, pid, wid, 1, 3, group);
  usleep(1000);
  cuaSend(src, kCGEventLeftMouseUp,   at,  lx,  ly, pid, wid, 1, 3, group);
  if (src) CFRelease(src);
}

// ── A drag through the same route ───────────────────────────────────────────
// No reference recipe exists: the driver this sequence came from refuses
// background drags outright. So this is the click sequence with the button
// kept down across intermediate points, and a switch for the one thing that
// made a drag carry its button on a Chromium surface earlier today — pressure.
static void cuaDragSend(CGEventSourceRef src, CGEventType type, CGPoint at, double lx, double ly,
                        pid_t pid, uint32_t wid, int64_t clickState, int64_t phase, int64_t group) {
  CGEventRef e = CGEventCreateMouseEvent(src, type, at, kCGMouseButtonLeft);
  if (!e) return;
  cuaField(e, 0, phase);
  cuaField(e, 1, clickState);
  cuaField(e, 3, 0);
  cuaField(e, 7, 3);
  cuaField(e, 40, pid);
  if (wid) { cuaField(e, 51, wid); cuaField(e, 91, wid); cuaField(e, 92, wid); }
  cuaField(e, 58, group);
  if (gPressure && (type == kCGEventLeftMouseDown || type == kCGEventLeftMouseDragged)) {
    CGEventSetDoubleValueField(e, kCGMouseEventPressure, 1.0);
    cuaField(e, 45, 1);
  }
  SetWinLocFn setWinLoc = (SetWinLocFn)S("CGEventSetWindowLocation");
  if (setWinLoc) setWinLoc((void *)e, lx, ly);
  cuaPost(e, pid);
  CFRelease(e);
}

static void cuaDrag(pid_t pid, uint32_t wid, CGPoint a, double alx, double aly,
                    CGPoint b, double blx, double bly) {
  printf("  drag %s pressure\n", gPressure ? "WITH" : "without");
  activateWithoutRaise(pid, wid);
  usleep(50000);
  CGEventSourceRef src = CGEventSourceCreate(kCGEventSourceStateHIDSystemState);
  int64_t group = (int64_t)(CFAbsoluteTimeGetCurrent() * 1e6);
  CGPoint off = CGPointMake(-1, -1);
  cuaDragSend(src, kCGEventMouseMoved,    a,   alx, aly, pid, wid, 0, 2, group);
  usleep(15000);
  cuaDragSend(src, kCGEventLeftMouseDown, off, -1,  -1,  pid, wid, 1, 1, group);
  usleep(1000);
  cuaDragSend(src, kCGEventLeftMouseUp,   off, -1,  -1,  pid, wid, 1, 2, group);
  usleep(100000);
  cuaDragSend(src, kCGEventLeftMouseDown, a,   alx, aly, pid, wid, 1, 3, group);
  usleep(16000);
  for (int i = 1; i <= 8; i++) {
    double t = (double)i / 9.0;
    CGPoint pt = CGPointMake(a.x + (b.x - a.x) * t, a.y + (b.y - a.y) * t);
    cuaDragSend(src, kCGEventLeftMouseDragged, pt, alx + (blx - alx) * t, aly + (bly - aly) * t,
                pid, wid, 1, 3, group);
    usleep(16000);
  }
  cuaDragSend(src, kCGEventLeftMouseDragged, b, blx, bly, pid, wid, 1, 3, group);
  usleep(16000);
  cuaDragSend(src, kCGEventLeftMouseUp,      b, blx, bly, pid, wid, 1, 3, group);
  if (src) CFRelease(src);
}
