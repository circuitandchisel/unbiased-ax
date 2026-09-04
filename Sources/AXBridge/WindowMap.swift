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
  /// session has a high id; this bounds the hunt. Paid once per unsettled wid.
  static let scanCap: UInt32 = 65_536
  /// A full cap scan takes about a second when the app answers. Past this the
  /// app is not answering, and a scan that keeps going is a hang, not a scan.
  static let scanBudget: TimeInterval = 3.0

  private(set) var byWid: [CGWindowID: AXElement] = [:]
  /// Every wid the window server listed that a completed scan has settled,
  /// mapped or not. What a full scan did not find will not appear later.
  /// An aborted scan settles nothing, so the next refresh tries again.
  private var settled: Set<CGWindowID> = []

  var elements: [AXElement] { Array(byWid.values) }

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
      guard let el = RemoteToken.element(pid: pid, elementId: id) else { break } // symbol missing: nothing to scan
      let (err, role) = Self.attr(el, kAXRoleAttribute)
      if err == .cannotComplete { aborted = true; break }
      guard err == .success, role == "AXWindow",
            let wid = RemoteToken.windowId(of: el), missing.contains(wid) else { continue }
      if Self.realSubroles.contains(Self.attr(el, kAXSubroleAttribute).1 ?? "") { byWid[wid] = AXElement(ref: el) }
      missing.remove(wid)
    }
    if LiveSource.debug {
      let ms = Int(Date().timeIntervalSince(started) * 1000)
      FileHandle.standardError.write("[ax] window scan pid \(pid): \(id) ids in \(ms)ms, \(byWid.count) real window(s), \(missing.count) wid(s) with no element\(aborted ? ", ABORTED: the app is not answering" : "")\n".data(using: .utf8)!)
    }
    if !aborted { settled = live }
  }

  private static func attr(_ el: AXUIElement, _ a: String) -> (AXError, String?) {
    var v: CFTypeRef?
    let e = AXUIElementCopyAttributeValue(el, a as CFString, &v)
    return (e, e == .success ? v as? String : nil)
  }

  /// Prove the mechanism on THIS machine before relying on it. An app with
  /// windows must yield a real window whose id the window server lists, and
  /// when that app has a public AXWindows element, a token rebuilt from scratch
  /// must be CFEqual to it. Anything less: cross-Space stays off and the bridge
  /// behaves exactly as before. Never guess with a private API that has stopped
  /// round-tripping.
  static func selfCheck() -> Bool {
    guard RemoteToken.available, AXIsProcessTrusted() else { return false }
    var candidates = NSWorkspace.shared.runningApplications.filter { $0.activationPolicy == .regular }
    if let f = NSWorkspace.shared.frontmostApplication, let i = candidates.firstIndex(of: f) { candidates.swapAt(0, i) }
    for a in candidates.prefix(3) {
      let pid = a.processIdentifier
      guard !serverWindows(pid: pid).isEmpty else { continue }
      let root = AXUIElementCreateApplication(pid)
      AXUIElementSetMessagingTimeout(root, RemoteToken.messagingTimeout)
      var v: CFTypeRef?
      if AXUIElementCopyAttributeValue(root, kAXWindowsAttribute as CFString, &v) == .success, let pub = axElements(v).first {
        guard let id = RemoteToken.elementId(of: pub), let rebuilt = RemoteToken.element(pid: pid, elementId: id), CFEqual(rebuilt, pub) else {
          if LiveSource.debug { FileHandle.standardError.write("[ax] cross-Space self-check: token round-trip failed on \(a.localizedName ?? "?")\n".data(using: .utf8)!) }
          return false
        }
      }
      var map = WindowMap()
      map.refresh(pid: pid)
      if !map.byWid.isEmpty {
        if LiveSource.debug { FileHandle.standardError.write("[ax] cross-Space self-check: ok via \(a.localizedName ?? "?")\n".data(using: .utf8)!) }
        return true
      }
    }
    return false
  }
}
