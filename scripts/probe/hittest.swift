// hittest <app> <x> <y> [<x> <y> ...]
// Read-only: asks the app what is at each screen point and prints the chain of
// ancestors up to the application, plus what currently has keyboard focus.
// Exists to check whether an app's hit test answers with deep nodes (so the
// bridge's pointer guard can tell "inside the anchor" from "somewhere else") or
// only with a top-level area (which would make the guard inert for that app).
import AppKit
import ApplicationServices

let args = CommandLine.arguments
guard args.count >= 4, (args.count - 2) % 2 == 0 else { print("usage: hittest <app> <x> <y> [<x> <y> ...]"); exit(2) }
let appName = args[1]
guard let app = NSWorkspace.shared.runningApplications.first(where: { ($0.localizedName ?? "").hasPrefix(appName) }) else { print("no app \(appName)"); exit(1) }
let root = AXUIElementCreateApplication(app.processIdentifier)
AXUIElementSetMessagingTimeout(root, 2)

func str(_ el: AXUIElement, _ attr: String) -> String? {
  var v: CFTypeRef?
  guard AXUIElementCopyAttributeValue(el, attr as CFString, &v) == .success else { return nil }
  return v as? String
}
func frame(_ el: AXUIElement) -> String {
  var p: CFTypeRef?, sz: CFTypeRef?
  guard AXUIElementCopyAttributeValue(el, kAXPositionAttribute as CFString, &p) == .success, let pv = p,
        AXUIElementCopyAttributeValue(el, kAXSizeAttribute as CFString, &sz) == .success, let sv = sz else { return "" }
  var pt = CGPoint.zero, size = CGSize.zero
  AXValueGetValue(pv as! AXValue, .cgPoint, &pt); AXValueGetValue(sv as! AXValue, .cgSize, &size)
  return " @\(Int(pt.x)),\(Int(pt.y)) \(Int(size.width))x\(Int(size.height))"
}
func describe(_ el: AXUIElement) -> String {
  let role = str(el, kAXRoleAttribute) ?? "?"; let sub = str(el, kAXSubroleAttribute)
  let title = str(el, kAXTitleAttribute) ?? str(el, kAXDescriptionAttribute) ?? ""
  return "\(role)\(sub.map { "/\($0)" } ?? "")\(title.isEmpty ? "" : " \"\(title.prefix(50))\"")\(frame(el))"
}
func chain(_ el: AXUIElement) -> [String] {
  var out: [String] = [describe(el)]; var cur = el
  for _ in 0..<40 {
    var p: CFTypeRef?
    guard AXUIElementCopyAttributeValue(cur, kAXParentAttribute as CFString, &p) == .success, let pp = p, CFGetTypeID(pp) == AXUIElementGetTypeID() else { break }
    cur = pp as! AXUIElement; out.append(describe(cur))
  }
  return out
}

var i = 2
while i + 1 < args.count {
  let x = Float(args[i]) ?? 0, y = Float(args[i+1]) ?? 0; i += 2
  var hit: AXUIElement?
  let err = AXUIElementCopyElementAtPosition(root, x, y, &hit)
  print("\n(\(Int(x)),\(Int(y))) -> \(err == .success ? "hit" : "AXError \(err.rawValue)")")
  if let hit { for (d, line) in chain(hit).enumerated() { print(String(repeating: "  ", count: d) + line) } }
}
var f: CFTypeRef?
if AXUIElementCopyAttributeValue(root, kAXFocusedUIElementAttribute as CFString, &f) == .success, let ff = f, CFGetTypeID(ff) == AXUIElementGetTypeID() {
  print("\nfocused: \(describe(ff as! AXUIElement))")
} else { print("\nfocused: (none reported)") }
