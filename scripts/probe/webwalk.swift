// Does Chromium serve WEB CONTENT for an OFF-Space window once AXEnhancedUserInterface is set? READ-ONLY.
import AppKit
import ApplicationServices
import Darwin
typealias CreateWithRemoteToken = @convention(c) (CFData) -> Unmanaged<AXUIElement>?
typealias GetWindow = @convention(c) (AXUIElement, UnsafeMutablePointer<CGWindowID>) -> AXError
func sym<T>(_ name: String, as: T.Type) -> T? {
  guard let p = dlsym(UnsafeMutableRawPointer(bitPattern: -2), name) else { return nil }
  return unsafeBitCast(p, to: T.self)
}
let args = CommandLine.arguments
guard args.count >= 2 else { print("usage: webwalk <app>"); exit(2) }
let wantName = args[1].lowercased()
guard let createRT = sym("_AXUIElementCreateWithRemoteToken", as: CreateWithRemoteToken.self),
      let getWindow = sym("_AXUIElementGetWindow", as: GetWindow.self) else { print("symbols missing"); exit(1) }
guard let app = NSWorkspace.shared.runningApplications.first(where: {
  $0.activationPolicy == .regular && ($0.localizedName ?? "").lowercased().hasPrefix(wantName)
}) else { print("no app matching \(wantName)"); exit(1) }
let pid = app.processIdentifier
let root = AXUIElementCreateApplication(pid)
AXUIElementSetMessagingTimeout(root, 2.0)
print("app: \(app.localizedName ?? "?") pid \(pid)   frontmost now: \(NSWorkspace.shared.frontmostApplication?.localizedName ?? "?")")
var wv: CFTypeRef?
_ = AXUIElementCopyAttributeValue(root, kAXWindowsAttribute as CFString, &wv)
print("public AXWindows on this Space: \(((wv as? [AnyObject]) ?? []).count)   (0 means the target is OFF-Space, which is the point)")

func token(_ id: UInt32) -> CFData {
  var d = Data(count: 20)
  d.withUnsafeMutableBytes { (b: UnsafeMutableRawBufferPointer) in
    b.storeBytes(of: UInt32(bitPattern: pid), toByteOffset: 0, as: UInt32.self)
    b.storeBytes(of: UInt32(0x636f636f), toByteOffset: 8, as: UInt32.self)
    b.storeBytes(of: id, toByteOffset: 12, as: UInt32.self)
  }
  return d as CFData
}
func attr(_ el: AXUIElement, _ a: String) -> (AXError, CFTypeRef?) {
  var v: CFTypeRef?
  let e = AXUIElementCopyAttributeValue(el, a as CFString, &v)
  return (e, v)
}
func s(_ el: AXUIElement, _ a: String) -> String? { attr(el, a).1 as? String }
func children(_ el: AXUIElement) -> [AXUIElement] {
  guard let arr = attr(el, kAXChildrenAttribute).1 as? [AnyObject] else { return [] }
  return arr.compactMap { CFGetTypeID($0) == AXUIElementGetTypeID() ? ($0 as! AXUIElement) : nil }
}

var found: AXUIElement? = nil
var winId: UInt32 = 0
var wid: CGWindowID = 0
for id in 0..<UInt32(4000) {
  guard let el = createRT(token(id))?.takeRetainedValue() else { continue }
  guard s(el, kAXRoleAttribute) == "AXWindow", s(el, kAXSubroleAttribute) == "AXStandardWindow" else { continue }
  var w: CGWindowID = 0
  _ = getWindow(el, &w)
  found = el; winId = id; wid = w
  break
}
guard let win = found else { print("no standard window found by brute force"); exit(1) }
print("standard window: element#\(winId) wid \(wid) title=\"\(s(win, kAXTitleAttribute) ?? "")\"")

func walk(_ label: String) {
  var budget = 8000
  var roles: [String: Int] = [:]
  var web = 0, inWeb = 0
  var webTitle = ""
  func go(_ e: AXUIElement, _ d: Int, _ underWeb: Bool) {
    guard budget > 0, d < 30 else { return }
    budget -= 1
    let r = s(e, kAXRoleAttribute) ?? "?"
    roles[r, default: 0] += 1
    var uw = underWeb
    if r == "AXWebArea" {
      web += 1; uw = true
      if webTitle.isEmpty { webTitle = s(e, kAXTitleAttribute) ?? s(e, kAXDescriptionAttribute) ?? "" }
    } else if underWeb { inWeb += 1 }
    for c in children(e) { go(c, d + 1, uw) }
  }
  let t = Date()
  go(win, 0, false)
  let top = roles.sorted { $0.value > $1.value }.prefix(10).map { "\($0.key)=\($0.value)" }.joined(separator: " ")
  print("\(label): \(8000 - budget) elements in \(Int(Date().timeIntervalSince(t) * 1000))ms\(budget == 0 ? " (budget hit)" : "") | AXWebArea=\(web) elementsUnderWeb=\(inWeb) webTitle=\"\(webTitle.prefix(50))\"")
  print("   \(top)")
}
walk("BEFORE web opt-in")
let e1 = AXUIElementSetAttributeValue(root, "AXEnhancedUserInterface" as CFString, kCFBooleanTrue)
let e2 = AXUIElementSetAttributeValue(win, "AXEnhancedUserInterface" as CFString, kCFBooleanTrue)
let (re, rv) = attr(root, "AXEnhancedUserInterface")
print("set AXEnhancedUserInterface: onRoot=AXError \(e1.rawValue) onWindow=AXError \(e2.rawValue); read-back from root: err=\(re.rawValue) value=\(rv.map { "\($0)" } ?? "nil")")
Thread.sleep(forTimeInterval: 1.5)
walk("AFTER web opt-in (+1.5s)")
