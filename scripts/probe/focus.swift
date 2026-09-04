// APPROVED ACTION TEST: focus Brave's address bar in an OFF-Space window, read back, hand focus to the web area.
// Records frontmost app + onscreen windows at each step to detect any Space/activation drag.
import AppKit
import ApplicationServices
import Darwin
typealias CreateWithRemoteToken = @convention(c) (CFData) -> Unmanaged<AXUIElement>?
typealias GetWindow = @convention(c) (AXUIElement, UnsafeMutablePointer<CGWindowID>) -> AXError
func sym<T>(_ name: String, as: T.Type) -> T? {
  guard let p = dlsym(UnsafeMutableRawPointer(bitPattern: -2), name) else { return nil }
  return unsafeBitCast(p, to: T.self)
}
guard let createRT = sym("_AXUIElementCreateWithRemoteToken", as: CreateWithRemoteToken.self),
      let getWindow = sym("_AXUIElementGetWindow", as: GetWindow.self) else { print("symbols missing"); exit(1) }
guard let app = NSWorkspace.shared.runningApplications.first(where: {
  $0.activationPolicy == .regular && ($0.localizedName ?? "").lowercased().hasPrefix("brave")
}) else { print("Brave not running"); exit(1) }
let pid = app.processIdentifier
let root = AXUIElementCreateApplication(pid)
AXUIElementSetMessagingTimeout(root, 2.0)

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
func focused(_ e: AXUIElement) -> String {
  let (err, v) = attr(e, kAXFocusedAttribute)
  return err == .success ? "\((v as? NSNumber)?.boolValue ?? false)" : "err\(err.rawValue)"
}
func state(_ label: String) {
  let front = NSWorkspace.shared.frontmostApplication?.localizedName ?? "?"
  let list = (CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]]) ?? []
  var owners = Set<String>()
  var braveOn = false
  for w in list where (w[kCGWindowLayer as String] as? Int) == 0 {
    owners.insert((w[kCGWindowOwnerName as String] as? String) ?? "?")
    if (w[kCGWindowOwnerPID as String] as? Int32) == pid { braveOn = true }
  }
  var wv: CFTypeRef?
  _ = AXUIElementCopyAttributeValue(root, kAXWindowsAttribute as CFString, &wv)
  print("[\(label)] frontmost=\(front)  onscreen owners=\(owners.sorted())  braveWindowOnscreen=\(braveOn)  bravePublicAXWindows=\(((wv as? [AnyObject]) ?? []).count)")
}

var wins: [(UInt32, AXUIElement, CGWindowID, String)] = []
for id in 0..<UInt32(4000) {
  guard let el = createRT(token(id))?.takeRetainedValue() else { continue }
  guard s(el, kAXRoleAttribute) == "AXWindow" else { continue }
  var w: CGWindowID = 0
  _ = getWindow(el, &w)
  wins.append((id, el, w, s(el, kAXSubroleAttribute) ?? "?"))
}
print("Brave AXWindow elements: \(wins.map { "#\($0.0)->wid\($0.2)(\($0.3))" }.joined(separator: "  "))")

var omni: AXUIElement? = nil
var omniWhere = ""
var webArea: AXUIElement? = nil
func find(_ e: AXUIElement, _ d: Int, _ label: String) {
  guard d < 20, omni == nil || webArea == nil else { return }
  let r = s(e, kAXRoleAttribute) ?? ""
  if r == "AXTextField", omni == nil {
    let t = ((s(e, kAXTitleAttribute) ?? "") + " " + (s(e, kAXDescriptionAttribute) ?? "")).trimmingCharacters(in: .whitespaces)
    if t.lowercased().contains("address") || t.lowercased().contains("search bar") { omni = e; omniWhere = "\(label) \"\(t)\"" }
  }
  if r == "AXWebArea", webArea == nil { webArea = e }
  for c in children(e) { find(c, d + 1, label) }
}
for (id, el, w, _) in wins { find(el, 0, "window#\(id)/wid\(w)") }
guard let omni else { print("omnibox not found"); exit(1) }
print("omnibox: \(omniWhere)   webArea found: \(webArea != nil)")

state("BEFORE")
print("omnibox AXFocused before: \(focused(omni))   webArea focused: \(webArea.map(focused) ?? "n/a")")
let t0 = Date()
let e1 = AXUIElementSetAttributeValue(omni, kAXFocusedAttribute as CFString, kCFBooleanTrue)
let ms1 = Int(Date().timeIntervalSince(t0) * 1000)
print("SET omnibox AXFocused=true -> AXError \(e1.rawValue) in \(ms1)ms   immediate read-back: \(focused(omni))")
Thread.sleep(forTimeInterval: 0.6)
state("AFTER focus (+0.6s)")
print("omnibox AXFocused after settle: \(focused(omni))")
if let webArea {
  let e2 = AXUIElementSetAttributeValue(webArea, kAXFocusedAttribute as CFString, kCFBooleanTrue)
  print("SET webArea AXFocused=true -> AXError \(e2.rawValue)   read-back omnibox: \(focused(omni))  webArea: \(focused(webArea))")
}
Thread.sleep(forTimeInterval: 0.6)
state("END (+0.6s)")
