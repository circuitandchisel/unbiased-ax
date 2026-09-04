// Identity: is an element rebuilt from a from-scratch token CFEqual to the public AXWindows element? READ-ONLY.
import AppKit
import ApplicationServices
import Darwin
typealias CreateWithRemoteToken = @convention(c) (CFData) -> Unmanaged<AXUIElement>?
typealias TokenCreate = @convention(c) (AXUIElement) -> Unmanaged<CFData>?
typealias GetWindow = @convention(c) (AXUIElement, UnsafeMutablePointer<CGWindowID>) -> AXError
func sym<T>(_ name: String, as: T.Type) -> T? {
  guard let p = dlsym(UnsafeMutableRawPointer(bitPattern: -2), name) else { return nil }
  return unsafeBitCast(p, to: T.self)
}
guard let createRT = sym("_AXUIElementCreateWithRemoteToken", as: CreateWithRemoteToken.self),
      let tokenCreate = sym("_AXUIElementRemoteTokenCreate", as: TokenCreate.self),
      let getWindow = sym("_AXUIElementGetWindow", as: GetWindow.self) else { print("symbols missing"); exit(1) }
func publicWindows(_ a: NSRunningApplication) -> [AXUIElement] {
  let r = AXUIElementCreateApplication(a.processIdentifier)
  AXUIElementSetMessagingTimeout(r, 0.5)
  var v: CFTypeRef?
  guard AXUIElementCopyAttributeValue(r, kAXWindowsAttribute as CFString, &v) == .success, let arr = v as? [AnyObject] else { return [] }
  return arr.compactMap { CFGetTypeID($0) == AXUIElementGetTypeID() ? ($0 as! AXUIElement) : nil }
}
var candidates: [NSRunningApplication] = []
if let f = NSWorkspace.shared.frontmostApplication { candidates.append(f) }
candidates += NSWorkspace.shared.runningApplications.filter { $0.activationPolicy == .regular && $0.localizedName != "Finder" }
var tested = 0
for a in candidates {
  let wins = publicWindows(a)
  if wins.isEmpty { continue }
  print("app: \(a.localizedName ?? "?") pid \(a.processIdentifier)   public windows on this Space: \(wins.count)")
  for w in wins {
    guard let tok = tokenCreate(w)?.takeRetainedValue() else { print("  no token"); continue }
    let d = tok as Data
    let hex = d.map { String(format: "%02x", $0) }.joined(separator: " ")
    guard d.count >= 16 else { print("  short token: \(hex)"); continue }
    let elementId = d.withUnsafeBytes { $0.load(fromByteOffset: 12, as: UInt32.self) }
    let tag = d.withUnsafeBytes { $0.load(fromByteOffset: 8, as: UInt32.self) }
    var mine = Data(count: 20)
    mine.withUnsafeMutableBytes { (b: UnsafeMutableRawBufferPointer) in
      b.storeBytes(of: UInt32(bitPattern: a.processIdentifier), toByteOffset: 0, as: UInt32.self)
      b.storeBytes(of: tag, toByteOffset: 8, as: UInt32.self)
      b.storeBytes(of: elementId, toByteOffset: 12, as: UInt32.self)
    }
    guard let rebuilt = createRT(mine as CFData)?.takeRetainedValue() else { print("  rebuild failed"); continue }
    var w1: CGWindowID = 0, w2: CGWindowID = 0
    _ = getWindow(w, &w1)
    _ = getWindow(rebuilt, &w2)
    var t: CFTypeRef?
    let title = AXUIElementCopyAttributeValue(rebuilt, kAXTitleAttribute as CFString, &t) == .success ? ((t as? String) ?? "") : "<err>"
    print("  real token: \(hex)")
    print("    elementId=\(elementId) tag=0x\(String(tag, radix: 16))  CFEqual(rebuilt,public)=\(CFEqual(rebuilt, w))  CFHash equal=\(CFHash(rebuilt) == CFHash(w))  getWindow public=\(w1) rebuilt=\(w2)  rebuilt title=\"\(title.prefix(40))\"")
    tested += 1
  }
  if tested > 0 { break }
}
if tested == 0 { print("no app with public windows on this Space right now") }
