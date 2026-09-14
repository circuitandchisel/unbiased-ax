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

static int gTransport = 0;   // 0 both, 1 SLEventPostToPid only, 2 CGEventPostToPid only
static BOOL gStampFields = YES;


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
  printf("  activate: defocus=%d focus=%d\n", defocus, focus);
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
  CFArrayRef all = CGWindowListCopyWindowInfo(kCGWindowListOptionOnScreenOnly | kCGWindowListExcludeDesktopElements, kCGNullWindowID);
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

  CGPoint home = CGEventGetLocation(CGEventCreate(NULL));
  printf("pid %d wid %u at (%.0f,%.0f)%s\n", pid, wid, at.x, at.y, hasWin ? " window-local set" : "");
  printf("  front before: %s   pointer at (%.0f,%.0f)\n", frontName().UTF8String, home.x, home.y);

  if (!noActivate) { activateWithoutRaise(pid, wid); usleep(50000); }
  printf("  front after activate: %s\n", frontName().UTF8String);
  if (activateOnly) return 0;

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

  usleep(120000);
  CGPoint now = CGEventGetLocation(CGEventCreate(NULL));
  printf("  posted move+down+up (both transports)\n");
  printf("  front after: %s   pointer now (%.0f,%.0f) — moved %s\n",
         frontName().UTF8String, now.x, now.y,
         (fabs(now.x - home.x) < 2 && fabs(now.y - home.y) < 2) ? "NO" : "YES");
  return 0;
} }
