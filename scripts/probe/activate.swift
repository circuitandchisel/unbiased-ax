// Which activation does a Catalyst app honour for an element that swallows
// AXPress? Measured need: Maps' search-result rows and its place card's
// "6 min" directions button returned AXError 0 for AXPress and did nothing,
// on and off Space (run 3 of the Maps task, 2026-09-05: twelve dead actions).
// MUTATING: performs the chosen activation on the matching element.
// usage: activate <app> <title-substring> <press|select|click|confirm|pick|focus-space|none> [--onspace]
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
guard args.count >= 4 else { print("usage: activate <app> <title-substring> <mode>"); exit(2) }
let wantName = args[1].lowercased(), needle = args[2].lowercased(), mode = args[3]
guard let createRT = sym("_AXUIElementCreateWithRemoteToken", as: CreateWithRemoteToken.self),
      let getWindow = sym("_AXUIElementGetWindow", as: GetWindow.self) else { print("symbols missing"); exit(1) }
guard let app = NSWorkspace.shared.runningApplications.first(where: {
  $0.activationPolicy == .regular && ($0.localizedName ?? "").lowercased().hasPrefix(wantName)
}) else { print("no app matching \(wantName)"); exit(1) }
let pid = app.processIdentifier
let root = AXUIElementCreateApplication(pid)
AXUIElementSetMessagingTimeout(root, 1.0)
print("app: \(app.localizedName ?? "?") pid \(pid)   frontmost now: \(NSWorkspace.shared.frontmostApplication?.localizedName ?? "?")")

func attr(_ el: AXUIElement, _ a: String) -> CFTypeRef? {
  var v: CFTypeRef?
  return AXUIElementCopyAttributeValue(el, a as CFString, &v) == .success ? v : nil
}
func str(_ el: AXUIElement, _ a: String) -> String { (attr(el, a) as? String) ?? "" }
func children(_ el: AXUIElement) -> [AXUIElement] {
  guard let arr = attr(el, kAXChildrenAttribute) as? [AnyObject] else { return [] }
  return arr.compactMap { CFGetTypeID($0) == AXUIElementGetTypeID() ? ($0 as! AXUIElement) : nil }
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

// The window: public AXWindows when on this Space, else the remote-token scan.
var windows: [AXUIElement] = (attr(root, kAXWindowsAttribute) as? [AnyObject] ?? []).compactMap { CFGetTypeID($0) == AXUIElementGetTypeID() ? ($0 as! AXUIElement) : nil }
if windows.isEmpty {
  _ = attr(root, kAXMainWindowAttribute) // vend it, so the app allocates an element id
  for id in 0..<UInt32(65_536) {
    guard let el = createRT(token(id))?.takeRetainedValue() else { continue }
    if (attr(el, kAXRoleAttribute) as? String) == "AXWindow", (attr(el, kAXSubroleAttribute) as? String) == "AXStandardWindow" {
      var w: CGWindowID = 0
      if getWindow(el, &w) == .success { windows.append(el); break }
    }
  }
}
guard let win = windows.first else { print("no window found"); exit(1) }
print("window: \"\(str(win, kAXTitleAttribute))\" (public AXWindows on this Space: \(attr(root, kAXWindowsAttribute) != nil))")

// Walk, collect every element, find the target.
var all: [(AXUIElement, Int)] = []
func walk(_ e: AXUIElement, _ d: Int) {
  guard all.count < 4000, d < 20 else { return }
  all.append((e, d))
  for c in children(e) { walk(c, d + 1) }
}
func fingerprint() -> (Int, Int) {
  all = []
  walk(win, 0)
  var h = 0
  for (e, _) in all { h = h &* 31 &+ (str(e, kAXRoleAttribute) + "|" + str(e, kAXTitleAttribute) + "|" + str(e, kAXValueAttribute)).hashValue }
  return (all.count, h)
}
let before = fingerprint()
print("tree: \(before.0) elements")
func describe(_ e: AXUIElement) -> String {
  let role = str(e, kAXRoleAttribute), sub = str(e, kAXSubroleAttribute), title = str(e, kAXTitleAttribute)
  let desc = str(e, kAXDescriptionAttribute), value = (attr(e, kAXValueAttribute) as? String) ?? ""
  var names: CFArray?
  let acts = AXUIElementCopyActionNames(e, &names) == .success ? ((names as? [String]) ?? []).map { $0.components(separatedBy: "\n").first ?? $0 }.joined(separator: ",") : "?"
  var pos = CGPoint.zero, size = CGSize.zero
  if let pv = attr(e, kAXPositionAttribute) { AXValueGetValue(pv as! AXValue, .cgPoint, &pos) }
  if let sv = attr(e, kAXSizeAttribute) { AXValueGetValue(sv as! AXValue, .cgSize, &size) }
  let sel = (attr(e, kAXSelectedAttribute) as? Bool) ?? false
  let parentRole = (attr(e, kAXParentAttribute)).map { str($0 as! AXUIElement, kAXRoleAttribute) } ?? "?"
  return "\(role)\(sub.isEmpty ? "" : "/\(sub)") title=\"\(title)\" desc=\"\(desc)\" value=\"\(value.prefix(40))\" selected=\(sel) parent=\(parentRole) @\(Int(pos.x)),\(Int(pos.y)) \(Int(size.width))x\(Int(size.height)) actions={\(acts)}"
}
let hits = all.filter { (e, _) in
  [str(e, kAXTitleAttribute), str(e, kAXDescriptionAttribute), (attr(e, kAXValueAttribute) as? String) ?? ""].contains { $0.lowercased().contains(needle) }
}
print("matches for \"\(needle)\": \(hits.count)")
for (e, d) in hits.prefix(8) { print("  depth \(d): \(describe(e))") }
guard let (target, _) = hits.first(where: { (e, _) in str(e, kAXRoleAttribute) != "AXStaticText" }) ?? hits.first else { exit(0) }
print("target: \(describe(target))")

func click(_ e: AXUIElement) {
  var pos = CGPoint.zero, size = CGSize.zero
  if let pv = attr(e, kAXPositionAttribute) { AXValueGetValue(pv as! AXValue, .cgPoint, &pos) }
  if let sv = attr(e, kAXSizeAttribute) { AXValueGetValue(sv as! AXValue, .cgSize, &size) }
  let p = CGPoint(x: pos.x + size.width / 2, y: pos.y + size.height / 2)
  print("posting mouse down/up to pid at \(Int(p.x)),\(Int(p.y))")
  for (type, btn) in [(CGEventType.leftMouseDown, CGMouseButton.left), (.leftMouseUp, .left)] {
    guard let ev = CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: p, mouseButton: btn) else { continue }
    ev.setIntegerValueField(.mouseEventClickState, value: 1)
    ev.postToPid(pid)
    usleep(60_000)
  }
}
let t0 = Date()
switch mode {
case "press": print("AXPress -> \(AXUIElementPerformAction(target, kAXPressAction as CFString).rawValue)")
case "confirm": print("AXConfirm -> \(AXUIElementPerformAction(target, kAXConfirmAction as CFString).rawValue)")
case "pick": print("AXPick -> \(AXUIElementPerformAction(target, kAXPickAction as CFString).rawValue)")
case "select": print("AXSelected=true -> \(AXUIElementSetAttributeValue(target, kAXSelectedAttribute as CFString, kCFBooleanTrue).rawValue)")
case "click": click(target)
case "focus-space":
  print("AXFocused=true -> \(AXUIElementSetAttributeValue(target, kAXFocusedAttribute as CFString, kCFBooleanTrue).rawValue)")
  for down in [true, false] { CGEvent(keyboardEventSource: nil, virtualKey: 49, keyDown: down)?.postToPid(pid); usleep(30_000) }
  print("posted space to pid")
case "press-parent":
  if let parent = attr(target, kAXParentAttribute) { print("AXPress on parent (\(str(parent as! AXUIElement, kAXRoleAttribute))) -> \(AXUIElementPerformAction(parent as! AXUIElement, kAXPressAction as CFString).rawValue)") }
case "press-front":
  // Activate the app (this switches Spaces), press, and put the previous app back.
  let previous = NSWorkspace.shared.frontmostApplication
  app.activate(options: [])
  usleep(900_000)
  print("frontmost during press: \(NSWorkspace.shared.frontmostApplication?.localizedName ?? "?")")
  print("AXPress -> \(AXUIElementPerformAction(target, kAXPressAction as CFString).rawValue)")
  usleep(1_200_000)
  previous?.activate(options: [])
case "click-front":
  let previous = NSWorkspace.shared.frontmostApplication
  app.activate(options: [])
  usleep(900_000)
  click(target)
  usleep(1_200_000)
  previous?.activate(options: [])
case "none": break
default: print("unknown mode"); exit(2)
}
// Did anything change, and when?
var changedAt: Int? = nil
for _ in 0..<30 {
  usleep(100_000)
  let now = fingerprint()
  if now != before { changedAt = Int(Date().timeIntervalSince(t0) * 1000); print("tree changed after \(changedAt!)ms: \(before.0) -> \(now.0) elements"); break }
}
if changedAt == nil { print("no change within 3s") }
print("frontmost now: \(NSWorkspace.shared.frontmostApplication?.localizedName ?? "?")")
