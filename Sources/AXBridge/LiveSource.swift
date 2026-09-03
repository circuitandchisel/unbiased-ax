import ApplicationServices
import Foundation
import AXModel

/// Reads elements over the Accessibility API. All attributes of an element
/// come back in ONE call (AXUIElementCopyMultipleAttributeValues); the naive
/// one-call-per-attribute approach is several times the IPC on a Chromium tree.
struct LiveSource: ElementSource {
  typealias Node = AXElement

  static let wanted: [String] = [
    kAXRoleAttribute, kAXSubroleAttribute, kAXTitleAttribute, kAXValueAttribute, kAXDescriptionAttribute,
    kAXPositionAttribute, kAXSizeAttribute, kAXEnabledAttribute, kAXFocusedAttribute, kAXSelectedAttribute,
  ]

  func identity(of node: AXElement) -> AnyHashable { node }

  func attributes(of node: AXElement) -> Attributes? {
    var values: CFArray?
    let err = AXUIElementCopyMultipleAttributeValues(node.ref, Self.wanted as CFArray, AXCopyMultipleAttributeOptions(), &values)
    guard err == .success, let arr = values as? [AnyObject], arr.count == Self.wanted.count else { return nil }

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
    func bool(_ i: Int) -> Bool { isAXValue(arr[i]) ? false : ((arr[i] as? Bool) ?? false) }
    func point(_ i: Int) -> CGPoint {
      var p = CGPoint.zero
      if isAXValue(arr[i]) { AXValueGetValue(arr[i] as! AXValue, .cgPoint, &p) }
      return p
    }
    func size(_ i: Int) -> CGSize {
      var s = CGSize.zero
      if isAXValue(arr[i]) { AXValueGetValue(arr[i] as! AXValue, .cgSize, &s) }
      return s
    }

    let role = Role.normalize(str(0) ?? "AXUnknown", subrole: str(1))
    // Title, else description: many controls only carry the latter.
    let title = str(2).flatMap { $0.isEmpty ? nil : $0 } ?? str(4)
    let p = point(5), s = size(6)

    // Actions cost one more IPC per element; only interactive roles can have
    // any a model would use, so structural nodes skip the call.
    var actions: [String] = []
    if Role.isInteractive(role) {
      var names: CFArray?
      if AXUIElementCopyActionNames(node.ref, &names) == .success, let a = names as? [String] {
        actions = a.map(Role.normalizeAction)
      }
    }
    return Attributes(role: role, title: title, value: str(3),
                      x: Int(p.x), y: Int(p.y), width: Int(s.width), height: Int(s.height),
                      actions: actions, enabled: bool(7), focused: bool(8), selected: bool(9))
  }

  func children(of node: AXElement) -> [AXElement] {
    var v: CFTypeRef?
    guard AXUIElementCopyAttributeValue(node.ref, kAXChildrenAttribute as CFString, &v) == .success else { return [] }
    return axElements(v).map(AXElement.init)
  }
}
