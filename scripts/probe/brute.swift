// Brute-force the app's AX element-id space via _AXUIElementCreateWithRemoteToken
// (token = pid,0,'coco',elementId,0) and map hits to windows. READ-ONLY.
// usage: brute <app> <maxId> [--walk]
import AppKit
import ApplicationServices
import Darwin

typealias CreateWithRemoteToken = @convention(c) (CFData) -> Unmanaged<AXUIElement>?
typealias GetWindow = @convention(c) (AXUIElement, UnsafeMutablePointer<CGWindowID>) -> AXError
func sym<T>(_ name: String, as: T.Type) -> T? {
  guard let p = dlsym(UnsafeMutableRawPointer(bitPattern: -2), name) else { return nil }
  return unsafeBitCast(p, to: T.self)
}
func hasAXWindows(_ a: NSRunningApplication) -> Bool {
  let r = AXUIElementCreateApplication(a.processIdentifier)
  AXUIElementSetMessagingTimeout(r, 0.5)
  var v: CFTypeRef?
  return AXUIElementCopyAttributeValue(r, kAXWindowsAttribute as CFString, &v) == .success && !(((v as? [AnyObject]) ?? []).isEmpty)
}
let args = CommandLine.arguments
guard args.count >= 3, let maxId = UInt32(args[2]) else { print("usage: brute <app> <maxId> [--walk]"); exit(2) }
let wantName = args[1].lowercased()
let doWalk = args.contains("--walk")
guard let createRT = sym("_AXUIElementCreateWithRemoteToken", as: CreateWithRemoteToken.self),
      let getWindow = sym("_AXUIElementGetWindow", as: GetWindow.self) else { print("symbols missing"); exit(1) }
guard let app = NSWorkspace.shared.runningApplications.first(where: {
  $0.activationPolicy == .regular && (wantName == "onspace" ? hasAXWindows($0) : ($0.localizedName ?? "").lowercased().hasPrefix(wantName))
}) else { print("no app matching \(wantName)"); exit(1) }
let pid = app.processIdentifier
let root = AXUIElementCreateApplication(pid)
AXUIElementSetMessagingTimeout(root, 1.0)
print("app: \(app.localizedName ?? "?") pid \(pid)   frontmost now: \(NSWorkspace.shared.frontmostApplication?.localizedName ?? "?")")

var wv: CFTypeRef?
_ = AXUIElementCopyAttributeValue(root, kAXWindowsAttribute as CFString, &wv)
let pub = ((wv as? [AnyObject]) ?? []).compactMap { CFGetTypeID($0) == AXUIElementGetTypeID() ? ($0 as! AXUIElement) : nil }
print("public AXWindows on this Space: \(pub.count)")
let cg = (CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID) as? [[String: Any]]) ?? []
var onscreen: [CGWindowID: Bool] = [:]
var names: [CGWindowID: String] = [:]
var sizes: [CGWindowID: String] = [:]
for w in cg where (w[kCGWindowOwnerPID as String] as? Int32) == pid {
  let id = CGWindowID((w[kCGWindowNumber as String] as? Int) ?? 0)
  onscreen[id] = (w[kCGWindowIsOnscreen as String] as? Bool) ?? false
  names[id] = (w[kCGWindowName as String] as? String) ?? ""
  let b = (w[kCGWindowBounds as String] as? [String: Any]) ?? [:]
  sizes[id] = "\(b["Width"] ?? "?")x\(b["Height"] ?? "?")"
}

func token(_ id: UInt32) -> CFData {
  var d = Data(count: 20)
  d.withUnsafeMutableBytes { (b: UnsafeMutableRawBufferPointer) in
    b.storeBytes(of: UInt32(bitPattern: pid), toByteOffset: 0, as: UInt32.self)
    b.storeBytes(of: UInt32(0x636f636f), toByteOffset: 8, as: UInt32.self)
    b.storeBytes(of: id, toByteOffset: 12, as: UInt32.self)
  }
  return d as CFData
}
func attr(_ el: AXUIElement, _ a: String) -> (AXError, String?) {
  var v: CFTypeRef?
  let e = AXUIElementCopyAttributeValue(el, a as CFString, &v)
  return (e, v as? String)
}
func children(_ el: AXUIElement) -> [AXUIElement] {
  var v: CFTypeRef?
  guard AXUIElementCopyAttributeValue(el, kAXChildrenAttribute as CFString, &v) == .success, let arr = v as? [AnyObject] else { return [] }
  return arr.compactMap { CFGetTypeID($0) == AXUIElementGetTypeID() ? ($0 as! AXUIElement) : nil }
}

let t0 = Date()
var resolved = 0
var errs: [Int32: Int] = [:]
var roles: [String: Int] = [:]
var windows: [(UInt32, AXUIElement)] = []
for id in 0..<maxId {
  guard let el = createRT(token(id))?.takeRetainedValue() else { continue }
  let (e, role) = attr(el, kAXRoleAttribute)
  if e != .success { errs[e.rawValue, default: 0] += 1; continue }
  resolved += 1
  roles[role ?? "?", default: 0] += 1
  if role == "AXWindow" { windows.append((id, el)) }
}
let ms = Int(Date().timeIntervalSince(t0) * 1000)
let topRoles = roles.sorted { $0.value > $1.value }.prefix(8).map { "\($0.key)=\($0.value)" }.joined(separator: " ")
print("scanned \(maxId) element ids in \(ms)ms: resolved=\(resolved) errors=\(errs) roles: \(topRoles)")
print("AXWindow elements found: \(windows.count)")
for (id, el) in windows {
  var w: CGWindowID = 0
  let gw = getWindow(el, &w) == .success ? w : 0
  let (_, title) = attr(el, kAXTitleAttribute)
  let (_, sub) = attr(el, kAXSubroleAttribute)
  let eqPub = pub.contains { CFEqual($0, el) }
  print("  element#\(id) -> wid \(gw) \(sizes[gw] ?? "?") onscreen=\(onscreen[gw] ?? false) inPublicAXWindows=\(eqPub) subrole=\(sub ?? "?") title=\"\((title ?? "").prefix(60))\"")
  if doWalk && !(onscreen[gw] ?? false) {
    var budget = 2000
    var rc: [String: Int] = [:]
    func walk(_ e: AXUIElement, _ d: Int) {
      guard budget > 0, d < 14 else { return }
      budget -= 1
      let (_, r) = attr(e, kAXRoleAttribute)
      rc[r ?? "?", default: 0] += 1
      for c in children(e) { walk(c, d + 1) }
    }
    let t1 = Date()
    walk(el, 0)
    let top = rc.sorted { $0.value > $1.value }.prefix(10).map { "\($0.key)=\($0.value)" }.joined(separator: " ")
    print("    OFF-SPACE WALK: \(2000 - budget) elements in \(Int(Date().timeIntervalSince(t1) * 1000))ms\(budget == 0 ? " (budget hit)" : ""): \(top)")
  }
}
