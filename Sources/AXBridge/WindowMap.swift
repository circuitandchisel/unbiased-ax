import AppKit
import ApplicationServices
import CoreGraphics
import Foundation

/// The windows of one process wherever they are: wid -> window element. Built
/// by scanning the app's element-id space through RemoteToken and keeping the
/// AXWindow hits — the mechanism AltTab ships as windowsByBruteForce. A cache:
/// rescanned only when the window server lists a wid this map has not settled.
struct WindowMap {
  /// Real windows only. Fullscreen toolbar panes are AXWindow with subrole
  /// AXUnknown and one element each; the system's per-app 3840x30 strips have
  /// no AX element at all. Neither is a window a model should be shown.
  static let realSubroles: Set<String> = ["AXStandardWindow", "AXDialog"]
  /// About a second at the measured 16µs per miss. Window elements are made
  /// early (ids 45–209 observed), but a window opened late in a long Chromium
  /// session has a high id; this bounds the hunt. Paid at most once per
  /// refresh that finds an unsettled wid, and to the cap only when one of them
  /// has no element — the system strips: once per app that has a real window,
  /// once per emptyRetry for one that does not. Not resumed from the highest
  /// id seen: that could not skip the strips' to-cap scan and would be unsafe
  /// if an app ever recycled ids.
  static let scanCap: UInt32 = 65_536
  /// A full cap scan takes about a second when the app answers. Past this the
  /// app is not answering, and a scan that keeps going is a hang, not a scan.
  static let scanBudget: TimeInterval = 3.0
  /// A refresh within this of the last one is a no-op: one verb calls in twice
  /// (snapshot, then the offscreen count), and the settle loop polls every
  /// 100ms. A window that appears inside the TTL is seen on the next refresh.
  static let refreshTTL: TimeInterval = 0.5
  /// While the map holds no real window — a fresh launch, an app with every
  /// window closed — the strips are re-scanned this often, so launch finds its
  /// window within a second of it being vended and a windowless app costs at
  /// most one scan per second, not one per read.
  static let emptyRetry: TimeInterval = 1.0

  private(set) var byWid: [CGWindowID: AXElement] = [:]
  /// Every wid the window server listed that a completed scan has settled,
  /// mapped or not: what a full scan did not find will not appear until
  /// something vends it. While the map holds no real window that could be any
  /// moment (a fresh launch), so the settled set expires every emptyRetry. An
  /// aborted scan settles nothing.
  private var settled: Set<CGWindowID> = []
  private var lastRefresh = Date.distantPast
  private var emptyScanAt: Date? = nil

  /// Sorted by wid — creation order — so root-child order, and where
  /// maxElements cuts, is the same on every read. Dictionary order moved the
  /// truncation boundary between two polls and looked like change.
  var elements: [AXElement] { byWid.sorted { $0.key < $1.key }.map(\.value) }

  /// Layer-0 windows the window server lists for the pid, on any Space.
  static func serverWindows(pid: pid_t) -> Set<CGWindowID> {
    let list = (CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID) as? [[String: Any]]) ?? []
    var out = Set<CGWindowID>()
    for w in list where (w[kCGWindowOwnerPID as String] as? Int32) == pid && ((w[kCGWindowLayer as String] as? Int) ?? 1) == 0 {
      if let n = w[kCGWindowNumber as String] as? Int { out.insert(CGWindowID(n)) }
    }
    return out
  }

  /// Windows the window server lists that are not the system's per-app strips
  /// (full-width, 30px). Used only when the map is empty, to tell "no window"
  /// from "a window the scan has not reached yet".
  static func unreachableCandidates(pid: pid_t) -> Int {
    let list = (CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID) as? [[String: Any]]) ?? []
    return list.filter {
      ($0[kCGWindowOwnerPID as String] as? Int32) == pid
        && (($0[kCGWindowLayer as String] as? Int) ?? 1) == 0
        && ((($0[kCGWindowBounds as String] as? [String: Any])?["Height"] as? Double) ?? 0) > 32
    }.count
  }

  /// Bring the map up to date with the window server. Free when nothing
  /// changed; one scan when a wid appeared that is not settled yet.
  ///
  /// A miss is a fast -25202 (invalidUIElement) and is skipped. A hung app
  /// does not miss: it answers -25204 (cannotComplete) after the messaging
  /// timeout on EVERY id, so that code aborts the scan at once — 65,536 of
  /// them would be a hang measured in hours. The wall-clock budget is the
  /// second net, for a hang that starts mid-scan or inside windowId(of:). A
  /// caller's `deadline` caps the wake and the scan as well — the self-check's
  /// clock, which one slow app must not stretch by a wake and a full scan.
  mutating func refresh(pid: pid_t, deadline: Date? = nil) {
    guard Date().timeIntervalSince(lastRefresh) >= Self.refreshTTL else { return }
    lastRefresh = Date()
    let live = Self.serverWindows(pid: pid)
    byWid = byWid.filter { live.contains($0.key) }
    // Empty by attrition counts as empty: a map whose last window just closed
    // has never scanned empty, so a nil timestamp means "already expired".
    if byWid.isEmpty, Date().timeIntervalSince(emptyScanAt ?? .distantPast) >= Self.emptyRetry { settled = [] }
    settled.formIntersection(live)
    var missing = live.subtracting(settled)
    guard !missing.isEmpty else { return }
    // Element ids exist only once a window has been VENDED to an AX client,
    // not from creation (measured: a Calculator launched with -g had no
    // element until AXMainWindow was read; AXWindows lists nothing off-screen
    // and vends nothing). Two reads on the root vend what a fresh app has, so
    // the scan below can find it.
    let outOfTime = deadline.map { Date() > $0 } ?? false
    if !outOfTime { Self.wake(pid: pid) }
    let started = Date()
    let until = min(started.addingTimeInterval(Self.scanBudget), deadline ?? .distantFuture)
    var id: UInt32 = 0
    var aborted = false
    while id < Self.scanCap, !missing.isEmpty {
      defer { id += 1 }
      if Date() > until { aborted = true; break }
      guard let el = RemoteToken.element(pid: pid, elementId: id) else { aborted = true; break } // nothing was checked; settle nothing
      let (err, role) = Self.attr(el, kAXRoleAttribute)
      if err == .cannotComplete { aborted = true; break }
      guard err == .success, role == "AXWindow",
            let wid = RemoteToken.windowId(of: el), live.contains(wid) else { continue }
      let (serr, sub) = Self.attr(el, kAXSubroleAttribute)
      if serr == .cannotComplete { aborted = true; break }
      if Self.realSubroles.contains(sub ?? "") { byWid[wid] = AXElement(ref: el) }
      missing.remove(wid)
    }
    let ms = Int(Date().timeIntervalSince(started) * 1000)
    Self.debugLog("window scan pid \(pid): \(id) ids in \(ms)ms, \(byWid.count) real window(s), \(missing.count) wid(s) with no element\(aborted ? ", ABORTED: the app is not answering" : "")")
    if !aborted {
      settled = live
      emptyScanAt = byWid.isEmpty ? Date() : nil
    }
  }

  private static func wake(pid: pid_t) {
    let root = AXUIElementCreateApplication(pid)
    AXUIElementSetMessagingTimeout(root, RemoteToken.messagingTimeout)
    for name in [kAXMainWindowAttribute, kAXFocusedWindowAttribute] {
      var v: CFTypeRef?
      if AXUIElementCopyAttributeValue(root, name as CFString, &v) == .cannotComplete { return }
    }
  }

  private static func attr(_ el: AXUIElement, _ a: String) -> (AXError, String?) {
    var v: CFTypeRef?
    let e = AXUIElementCopyAttributeValue(el, a as CFString, &v)
    return (e, e == .success ? v as? String : nil)
  }

  /// Startup proof of the mechanism, bounded by wall clock rather than by a
  /// count of apps: three unlucky candidates would otherwise cost three cap
  /// scans and the app side's hello timeout.
  static let selfCheckBudget: TimeInterval = 5.0

  /// Prove the mechanism on THIS machine before relying on it. An app with a
  /// public AXWindows window that has a window id is a witness: a token
  /// rebuilt from scratch must be CFEqual to that element, and a scan must
  /// then map at least one real window. Every witness is tried; one failure is
  /// that window's shape, not the machine's (Finder's desktop has no window id
  /// and does not round-trip). A definitive no — missing symbols, or no
  /// witness at all round-trips — is false. Not trusted, or nothing to witness
  /// with, is nil: undecided, ask again later. Never guess with a private API
  /// that has stopped round-tripping.
  static func selfCheck() -> Bool? {
    guard RemoteToken.available else { debugLog("cross-Space self-check: private symbols missing; off"); return false }
    guard AXIsProcessTrusted() else { debugLog("cross-Space self-check: not trusted; undecided"); return nil }
    let deadline = Date().addingTimeInterval(selfCheckBudget)
    // Every regular app owns the four system strips, so "has server windows"
    // selects nothing. A public AXWindows window does: it is a real window on
    // this Space, and it lets the identity check run — the stronger proof.
    var withPublic: [(NSRunningApplication, AXUIElement)] = []
    var without: [NSRunningApplication] = []
    for a in NSWorkspace.shared.runningApplications where a.activationPolicy == .regular {
      if Date() > deadline { break }
      let root = AXUIElementCreateApplication(a.processIdentifier)
      AXUIElementSetMessagingTimeout(root, RemoteToken.messagingTimeout)
      var v: CFTypeRef?
      let err = AXUIElementCopyAttributeValue(root, kAXWindowsAttribute as CFString, &v)
      if err == .success, let pub = axElements(v).first(where: { RemoteToken.windowId(of: $0) != nil }) {
        withPublic.append((a, pub))
      } else if err != .cannotComplete {
        without.append(a)
      }
    }
    if let f = NSWorkspace.shared.frontmostApplication, let i = withPublic.firstIndex(where: { $0.0 == f }) { withPublic.swapAt(0, i) }
    var roundTripFailed = false
    var anyRoundTripped = false
    for (a, pub) in withPublic {
      if Date() > deadline { break }
      let pid = a.processIdentifier
      let name = a.localizedName ?? "?"
      guard let id = RemoteToken.elementId(of: pub), let rebuilt = RemoteToken.element(pid: pid, elementId: id), CFEqual(rebuilt, pub) else {
        debugLog("cross-Space self-check: token round-trip failed on \(name); trying the next witness")
        roundTripFailed = true
        continue
      }
      anyRoundTripped = true
      var map = WindowMap()
      map.refresh(pid: pid, deadline: deadline)
      if !map.byWid.isEmpty { debugLog("cross-Space self-check: ok via \(name)"); return true }
    }
    for a in without {
      if Date() > deadline { break }
      var map = WindowMap()
      map.refresh(pid: a.processIdentifier, deadline: deadline)
      if !map.byWid.isEmpty { debugLog("cross-Space self-check: ok via \(a.localizedName ?? "?") (no public window to compare)"); return true }
    }
    if roundTripFailed && !anyRoundTripped { debugLog("cross-Space self-check: no witness round-tripped; off"); return false }
    debugLog("cross-Space self-check: no app yielded a real window within \(Int(selfCheckBudget))s; undecided")
    return nil
  }

  private static func debugLog(_ s: String) {
    if LiveSource.debug { FileHandle.standardError.write("[ax] \(s)\n".data(using: .utf8)!) }
  }
}
