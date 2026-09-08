import ApplicationServices
import Foundation
import AXModel

/// Reads elements over the Accessibility API. All attributes of an element
/// come back in ONE call (AXUIElementCopyMultipleAttributeValues); the naive
/// one-call-per-attribute approach is several times the IPC on a Chromium tree.
struct LiveSource: ElementSource {
  typealias Node = AXElement
  /// The application element this source was made for. Chromium apps list
  /// only their menu bar under the root's AXChildren; windows live under
  /// AXWindows. Measured on Brave: tree came back as the menu bar alone.
  var appRoot: AXElement? = nil
  /// Windows AXWindows cannot list — on another Space — reached through
  /// RemoteToken. They hang off the root like any other window.
  var extraWindows: [AXElement] = []
  /// UNBIASED_AX_DEBUG=1 logs every AX read failure to stderr with its code.
  static let debug = ProcessInfo.processInfo.environment["UNBIASED_AX_DEBUG"] == "1"
  /// Debug lines go to stderr AND, with UNBIASED_AX_DEBUG=1, to a file: the
  /// app that spawns the bridge is itself launched through `open`, which
  /// discards its console, so stderr alone told us nothing about a launch.
  static func trace(_ line: String) {
    guard debug else { return }
    let stamped = "\(Self.stamp()) \(line)\n"
    FileHandle.standardError.write("[ax] \(stamped)".data(using: .utf8)!)
    if let h = FileHandle(forWritingAtPath: "/tmp/unbiased-ax-bridge.log") ?? Self.createLog() {
      h.seekToEndOfFile(); h.write(stamped.data(using: .utf8)!); h.closeFile()
    }
  }
  private static func createLog() -> FileHandle? {
    FileManager.default.createFile(atPath: "/tmp/unbiased-ax-bridge.log", contents: nil)
    return FileHandle(forWritingAtPath: "/tmp/unbiased-ax-bridge.log")
  }
  private static func stamp() -> String {
    let f = DateFormatter(); f.dateFormat = "HH:mm:ss.SSS"; return f.string(from: Date())
  }

  static let wanted: [String] = [
    kAXRoleAttribute, kAXSubroleAttribute, kAXTitleAttribute, kAXValueAttribute, kAXDescriptionAttribute,
    kAXPositionAttribute, kAXSizeAttribute, kAXEnabledAttribute, kAXFocusedAttribute, kAXSelectedAttribute,
  ]

  func identity(of node: AXElement) -> AnyHashable { node }

  func attributes(of node: AXElement) -> Attributes? {
    var values: CFArray?
    let err = AXUIElementCopyMultipleAttributeValues(node.ref, Self.wanted as CFArray, AXCopyMultipleAttributeOptions(), &values)
    guard err == .success, let arr = values as? [AnyObject], arr.count == Self.wanted.count else {
      if Self.debug { FileHandle.standardError.write("[ax] attributes failed: AXError \(err.rawValue)\n".data(using: .utf8)!) }
      return nil
    }

    // Attributes the element lacks come back as AXValue error placeholders.
    func isAXValue(_ v: AnyObject) -> Bool { CFGetTypeID(v) == AXValueGetTypeID() }
    func str(_ i: Int) -> String? {
      let v = arr[i]
      if isAXValue(v) { return nil }
      if let s = v as? String { return s }
      if let n = v as? NSNumber { return n.stringValue }
      if let u = v as? URL { return u.absoluteString }
      return nil
    }
    func bool(_ i: Int, absent: Bool = false) -> Bool { isAXValue(arr[i]) ? absent : ((arr[i] as? Bool) ?? absent) }
    // AXValueGetValue returns false for an error placeholder (or any AXValue of
    // another type), which is how "this element has no geometry" is detected.
    func point(_ i: Int) -> CGPoint? {
      var p = CGPoint.zero
      return isAXValue(arr[i]) && AXValueGetValue(arr[i] as! AXValue, .cgPoint, &p) ? p : nil
    }
    func size(_ i: Int) -> CGSize? {
      var s = CGSize.zero
      return isAXValue(arr[i]) && AXValueGetValue(arr[i] as! AXValue, .cgSize, &s) ? s : nil
    }

    let role = Role.normalize(str(0) ?? "AXUnknown", subrole: str(1))
    // Title, else description: many controls only carry the latter.
    let title = str(2).flatMap { $0.isEmpty ? nil : $0 } ?? str(4)
    let p = point(5) ?? .zero
    let sizeValue = size(6)
    let s = sizeValue ?? .zero

    // Actions cost one more IPC per element; only interactive roles can have
    // any a model would use, so structural nodes skip the call.
    var actions: [String] = []
    if Role.isInteractive(role) {
      var names: CFArray?
      if AXUIElementCopyActionNames(node.ref, &names) == .success, let a = names as? [String] {
        actions = a.map(Role.normalizeAction)
      }
    }
    var out = Attributes(role: role, title: title, value: str(3),
                         x: Int(p.x), y: Int(p.y), width: Int(s.width), height: Int(s.height),
                         // An element that does not report AXEnabled is not disabled.
                         actions: actions, enabled: bool(7, absent: true), focused: bool(8), selected: bool(9))
    out.geometryKnown = sizeValue != nil
    return out
  }

  func children(of node: AXElement) -> [AXElement] {
    var v: CFTypeRef?
    let err = AXUIElementCopyAttributeValue(node.ref, kAXChildrenAttribute as CFString, &v)
    if err != .success && Self.debug { FileHandle.standardError.write("[ax] children failed: AXError \(err.rawValue)\n".data(using: .utf8)!) }
    var kids = err == .success ? axElements(v).map(AXElement.init) : []
    if let root = appRoot, node == root {
      var w: CFTypeRef?
      if AXUIElementCopyAttributeValue(node.ref, kAXWindowsAttribute as CFString, &w) == .success {
        for win in axElements(w).map(AXElement.init) where !kids.contains(win) { kids.append(win) }
      }
      for win in extraWindows where !kids.contains(win) { kids.append(win) }
    }
    return kids
  }
}
