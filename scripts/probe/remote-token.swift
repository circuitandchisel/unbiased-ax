// Feasibility spike: can we get a working AXUIElement for a window on ANOTHER
// Space via the private _AXUIElementCreateWithRemoteToken, and read its tree?
// READ-ONLY. No actions, no setValue. Reports roles/titles/counts only.
//
// usage: remote-token <app name prefix> [--web]
import AppKit
import ApplicationServices
import Darwin

typealias CreateWithRemoteToken = @convention(c) (CFData) -> Unmanaged<AXUIElement>?
typealias GetWindow = @convention(c) (AXUIElement, UnsafeMutablePointer<CGWindowID>) -> AXError

func sym<T>(_ name: String, as: T.Type) -> T? {
  guard let p = dlsym(UnsafeMutableRawPointer(bitPattern: -2), name) else { return nil } // RTLD_DEFAULT
  return unsafeBitCast(p, to: T.self)
}

let args = CommandLine.arguments
guard args.count >= 2 else { print("usage: remote-token <app> [--web]"); exit(2) }
let wantName = args[1].lowercased()
let web = args.contains("--web")

print("trusted: \(AXIsProcessTrusted())")
// System state first: if NOTHING is onscreen, every "off-Space" conclusion is suspect.
print("display asleep: \(CGDisplayIsAsleep(CGMainDisplayID()) != 0)  screens: \(NSScreen.screens.count)  frontmost: \(NSWorkspace.shared.frontmostApplication?.localizedName ?? "nil")")
if let sess = CGSessionCopyCurrentDictionary() as? [String: Any] {
  print("session: onConsole=\(sess["kCGSSessionOnConsoleKey"] ?? "?") screenLocked=\(sess["CGSSessionScreenIsLocked"] ?? "no-key") loginDone=\(sess["kCGSessionLoginDoneKey"] ?? "?")")
}
let onscreenAll = (CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]]) ?? []
var byOwner: [String: Int] = [:]
for w in onscreenAll where (w[kCGWindowLayer as String] as? Int) == 0 {
  byOwner[(w[kCGWindowOwnerName as String] as? String) ?? "?", default: 0] += 1
}
print("onscreen layer-0 windows system-wide: \(byOwner.values.reduce(0, +)) — \(byOwner.sorted { $0.value > $1.value }.prefix(10).map { "\($0.key)=\($0.value)" }.joined(separator: " "))")
guard let createRT = sym("_AXUIElementCreateWithRemoteToken", as: CreateWithRemoteToken.self) else {
  print("SYMBOL MISSING: _AXUIElementCreateWithRemoteToken"); exit(1)
}
let getWindow = sym("_AXUIElementGetWindow", as: GetWindow.self)
typealias TokenCreate = @convention(c) (AXUIElement) -> Unmanaged<CFData>?
let tokenCreate = sym("_AXUIElementRemoteTokenCreate", as: TokenCreate.self)
print("symbols: createWithRemoteToken=ok getWindow=\(getWindow == nil ? "MISSING" : "ok") remoteTokenCreate=\(tokenCreate == nil ? "MISSING" : "ok")")

func hex(_ d: Data) -> String { d.map { String(format: "%02x", $0) }.joined(separator: " ") }
func roleErr(_ el: AXUIElement) -> String {
  var v: CFTypeRef?
  let e = AXUIElementCopyAttributeValue(el, kAXRoleAttribute as CFString, &v)
  return e == .success ? "ok(\((v as? String) ?? "?"))" : "AXError \(e.rawValue)"
}

func hasAXWindows(_ a: NSRunningApplication) -> Bool {
  let r = AXUIElementCreateApplication(a.processIdentifier)
  AXUIElementSetMessagingTimeout(r, 0.5)
  var v: CFTypeRef?
  return AXUIElementCopyAttributeValue(r, kAXWindowsAttribute as CFString, &v) == .success && !(((v as? [AnyObject]) ?? []).isEmpty)
}
let regular = NSWorkspace.shared.runningApplications.filter { $0.activationPolicy == .regular }
// "onspace" picks whatever app has a window on the current Space right now, so
// the control does not race the user's Space switches.
let picked: NSRunningApplication? = wantName == "onspace"
  ? regular.first(where: hasAXWindows)
  : regular.first(where: { ($0.localizedName ?? "").lowercased().hasPrefix(wantName) })
guard let app = picked else { print("no app matching \(wantName)"); exit(1) }
let pid = app.processIdentifier
print("app: \(app.localizedName ?? "?") pid \(pid)")

let root = AXUIElementCreateApplication(pid)
AXUIElementSetMessagingTimeout(root, 1.0)
if web {
  let e = AXUIElementSetAttributeValue(root, "AXEnhancedUserInterface" as CFString, kCFBooleanTrue)
  print("set AXEnhancedUserInterface: AXError \(e.rawValue)")
}

func str(_ el: AXUIElement, _ attr: String) -> String? {
  var v: CFTypeRef?
  guard AXUIElementCopyAttributeValue(el, attr as CFString, &v) == .success else { return nil }
  return v as? String
}
func children(_ el: AXUIElement) -> [AXUIElement] {
  var v: CFTypeRef?
  guard AXUIElementCopyAttributeValue(el, kAXChildrenAttribute as CFString, &v) == .success,
        let arr = v as? [AnyObject] else { return [] }
  return arr.compactMap { CFGetTypeID($0) == AXUIElementGetTypeID() ? ($0 as! AXUIElement) : nil }
}
func wid(_ el: AXUIElement) -> CGWindowID? {
  guard let gw = getWindow else { return nil }
  var w: CGWindowID = 0
  return gw(el, &w) == .success ? w : nil
}
/// Bounded walk: count elements, and count "web area" descendants separately.
func walk(_ el: AXUIElement, depth: Int, budget: inout Int, roles: inout [String: Int]) {
  guard budget > 0, depth < 12 else { return }
  budget -= 1
  let role = str(el, kAXRoleAttribute) ?? "?"
  roles[role, default: 0] += 1
  for c in children(el) { walk(c, depth: depth + 1, budget: &budget, roles: &roles) }
}

// 1. AXWindows: what the public path sees (current Space only).
var wv: CFTypeRef?
let werr = AXUIElementCopyAttributeValue(root, kAXWindowsAttribute as CFString, &wv)
let axWindows = ((wv as? [AnyObject]) ?? []).compactMap { CFGetTypeID($0) == AXUIElementGetTypeID() ? ($0 as! AXUIElement) : nil }
print("\nAXWindows (public, this Space): err=\(werr.rawValue) count=\(axWindows.count)")
var axWids = Set<CGWindowID>()
if let tc = tokenCreate, let t = tc(root)?.takeRetainedValue() {
  print("app-root REAL token (\(CFDataGetLength(t)) bytes): \(hex(t as Data))")
}
for w in axWindows {
  let id = wid(w)
  if let id { axWids.insert(id) }
  let tok: CFData? = tokenCreate.flatMap { $0(w)?.takeRetainedValue() }
  print("  wid=\(id.map(String.init) ?? "?") role=\(str(w, kAXRoleAttribute) ?? "nil") title=\"\(str(w, kAXTitleAttribute) ?? "")\"")
  print("    REAL token (\(tok.map { CFDataGetLength($0) } ?? -1) bytes): \(tok.map { hex($0 as Data) } ?? "n/a")")
}

// 2. CGWindowList: every layer-0 window of the app, on any Space (public).
let list = (CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID) as? [[String: Any]]) ?? []
let mine = list.filter {
  ($0[kCGWindowOwnerPID as String] as? Int32) == pid && (($0[kCGWindowLayer as String] as? Int) ?? 1) == 0
}
print("\nCGWindowList (public, all Spaces): \(mine.count) layer-0 windows")

// 3. For each, build a remote-token element and try to read it.
func remoteTokenData(pid: pid_t, wid: CGWindowID) -> Data {
  var data = Data(count: 20)
  data.withUnsafeMutableBytes { (b: UnsafeMutableRawBufferPointer) in
    b.storeBytes(of: UInt32(bitPattern: pid), toByteOffset: 0, as: UInt32.self)
    b.storeBytes(of: UInt32(0), toByteOffset: 4, as: UInt32.self)
    b.storeBytes(of: UInt32(0x636f636f), toByteOffset: 8, as: UInt32.self) // 'coco'
    b.storeBytes(of: UInt32(wid), toByteOffset: 12, as: UInt32.self)
    b.storeBytes(of: UInt32(0), toByteOffset: 16, as: UInt32.self)
  }
  return data
}
func remoteElement(pid: pid_t, wid: CGWindowID) -> AXUIElement? {
  createRT(remoteTokenData(pid: pid, wid: wid) as CFData)?.takeRetainedValue()
}

for w in mine {
  let id = CGWindowID((w[kCGWindowNumber as String] as? Int) ?? 0)
  let onscreen = (w[kCGWindowIsOnscreen as String] as? Bool) ?? false
  let inAX = axWids.contains(id)
  let bounds = (w[kCGWindowBounds as String] as? [String: Any]) ?? [:]
  let size = "\(bounds["Width"] ?? "?")x\(bounds["Height"] ?? "?")"
  let alpha = w[kCGWindowAlpha as String] ?? "?", mem = w[kCGWindowMemoryUsage as String] ?? "?"
  let store = w[kCGWindowStoreType as String] ?? "?", share = w[kCGWindowSharingState as String] ?? "?"
  let name = w[kCGWindowName as String] ?? "(no name key)"
  print("\n— wid \(id) onscreen=\(onscreen) inAXWindows=\(inAX) \(size) alpha=\(alpha) mem=\(mem) store=\(store) share=\(share) name=\(name)")
  guard let el = remoteElement(pid: pid, wid: id) else { print("  remote token: nil"); continue }
  AXUIElementSetMessagingTimeout(el, 1.0)
  let role = str(el, kAXRoleAttribute)
  let title = str(el, kAXTitleAttribute)
  let rt = wid(el)
  print("  remote element: role=\(roleErr(el)) title=\"\(title ?? "")\" getWindow->\(rt.map(String.init) ?? "nil")")
  print("    constructed token: \(hex(remoteTokenData(pid: pid, wid: id)))")
  if role == nil { print("  (unreadable)"); continue }
  // identity check against the public element, when this window is on-Space
  if inAX, let pub = axWindows.first(where: { wid($0) == id }) {
    print("  CFEqual(remote, public)=\(CFEqual(el, pub)) hashEqual=\(CFHash(el) == CFHash(pub))")
  }
  var budget = 1500
  var roles: [String: Int] = [:]
  let t0 = Date()
  walk(el, depth: 0, budget: &budget, roles: &roles)
  let ms = Int(Date().timeIntervalSince(t0) * 1000)
  let n = 1500 - budget
  let top = roles.sorted { $0.value > $1.value }.prefix(8).map { "\($0.key)=\($0.value)" }.joined(separator: " ")
  print("  walked \(n) elements in \(ms)ms\(budget == 0 ? " (budget hit)" : ""): \(top)")
}
print("\ndone")
