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
  /// has no element — the system strips, so once per app. Not resumed from the
  /// highest id seen: that could not skip the strips' to-cap scan and would be
  /// unsafe if an app ever recycled ids.
  static let scanCap: UInt32 = 65_536
  /// A full cap scan takes about a second when the app answers. Past this the
  /// app is not answering, and a scan that keeps going is a hang, not a scan.
  static let scanBudget: TimeInterval = 3.0

  private(set) var byWid: [CGWindowID: AXElement] = [:]
  /// Every wid the window server listed that a completed scan has settled,
  /// mapped or not. What a full scan did not find will not appear later.
  /// An aborted scan settles nothing, so the next refresh tries again.
  private var settled: Set<CGWindowID> = []

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

  /// Bring the map up to date with the window server. Free when nothing
  /// changed; one scan when a wid appeared that is not settled yet.
  ///
  /// A miss is a fast -25202 (invalidUIElement) and is skipped. A hung app
  /// does not miss: it answers -25204 (cannotComplete) after the messaging
  /// timeout on EVERY id, so that code aborts the scan at once — 65,536 of
  /// them would be a hang measured in hours. The wall-clock budget is the
  /// second net, for a hang that starts mid-scan or inside windowId(of:).
  mutating func refresh(pid: pid_t) {
    let live = Self.serverWindows(pid: pid)
    byWid = byWid.filter { live.contains($0.key) }
    settled.formIntersection(live)
    var missing = live.subtracting(settled)
    guard !missing.isEmpty else { return }
    let started = Date()
    var id: UInt32 = 0
    var aborted = false
    while id < Self.scanCap, !missing.isEmpty {
      defer { id += 1 }
      if Date().timeIntervalSince(started) > Self.scanBudget { aborted = true; break }
      guard let el = RemoteToken.element(pid: pid, elementId: id) else { aborted = true; break } // nothing was checked; settle nothing
      let (err, role) = Self.attr(el, kAXRoleAttribute)
      if err == .cannotComplete { aborted = true; break }
      guard err == .success, role == "AXWindow",
            let wid = RemoteToken.windowId(of: el), missing.contains(wid) else { continue }
      let (serr, sub) = Self.attr(el, kAXSubroleAttribute)
      if serr == .cannotComplete { aborted = true; break }
      if Self.realSubroles.contains(sub ?? "") { byWid[wid] = AXElement(ref: el) }
      missing.remove(wid)
    }
    let ms = Int(Date().timeIntervalSince(started) * 1000)
    Self.debugLog("window scan pid \(pid): \(id) ids in \(ms)ms, \(byWid.count) real window(s), \(missing.count) wid(s) with no element\(aborted ? ", ABORTED: the app is not answering" : "")")
    if !aborted { settled = live }
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
  /// public AXWindows window is the best witness: a token rebuilt from scratch
  /// must be CFEqual to that element, and a scan must then map at least one
  /// real window. Without any such app, a scan that maps a real window is
  /// accepted alone. A definitive no — missing symbols, a token that does not
  /// round-trip — is false. Not trusted, or no app to witness with, is nil:
  /// undecided, ask again later. Never guess with a private API that has
  /// stopped round-tripping.
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
      if AXUIElementCopyAttributeValue(root, kAXWindowsAttribute as CFString, &v) == .success, let pub = axElements(v).first {
        withPublic.append((a, pub))
      } else {
        without.append(a)
      }
    }
    if let f = NSWorkspace.shared.frontmostApplication, let i = withPublic.firstIndex(where: { $0.0 == f }) { withPublic.swapAt(0, i) }
    for (a, pub) in withPublic {
      if Date() > deadline { break }
      let pid = a.processIdentifier
      guard let id = RemoteToken.elementId(of: pub), let rebuilt = RemoteToken.element(pid: pid, elementId: id), CFEqual(rebuilt, pub) else {
        debugLog("cross-Space self-check: token round-trip failed on \(a.localizedName ?? "?"); off")
        return false
      }
      var map = WindowMap()
      map.refresh(pid: pid)
      if !map.byWid.isEmpty { debugLog("cross-Space self-check: ok via \(a.localizedName ?? "?")"); return true }
    }
    for a in without {
      if Date() > deadline { break }
      var map = WindowMap()
      map.refresh(pid: a.processIdentifier)
      if !map.byWid.isEmpty { debugLog("cross-Space self-check: ok via \(a.localizedName ?? "?") (no public window to compare)"); return true }
    }
    debugLog("cross-Space self-check: no app yielded a real window within \(Int(selfCheckBudget))s; undecided")
    return nil
  }

  private static func debugLog(_ s: String) {
    if LiveSource.debug { FileHandle.standardError.write("[ax] \(s)\n".data(using: .utf8)!) }
  }
}
