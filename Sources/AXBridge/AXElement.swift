import ApplicationServices

/// AXUIElementRef with value semantics for hashing: two refs to the same
/// on-screen element are CFEqual, which is exactly what "the same button as in
/// the last snapshot" means. This is what makes stable ids possible.
struct AXElement: Hashable {
  let ref: AXUIElement
  static func == (a: AXElement, b: AXElement) -> Bool { CFEqual(a.ref, b.ref) }
  func hash(into h: inout Hasher) { h.combine(CFHash(a: ref)) }
}

private func CFHash(a: AXUIElement) -> Int { Int(bitPattern: UInt(ApplicationServices.CFHash(a))) }

/// A CFArray that may hold AXUIElements, as a Swift array, without trusting
/// `as? [AXUIElement]` — bridging CF types through arrays is not reliable.
func axElements(_ value: CFTypeRef?) -> [AXUIElement] {
  guard let arr = value as? [AnyObject] else { return [] }
  return arr.compactMap { CFGetTypeID($0) == AXUIElementGetTypeID() ? ($0 as! AXUIElement) : nil }
}
