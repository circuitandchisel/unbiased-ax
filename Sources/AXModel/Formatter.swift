/// One line per element, indented by depth. Compact, but readable to a person,
/// because the model reads it the way a person would.
///
///   3     text field "Address and search bar" = youtube.com/ [focused] {press}
///
/// The id is NOT indented and the role is: ids stay in a column a reader can
/// scan, the indentation shows structure. Geometry is appended only on request;
/// most turns are about WHAT is there, not where.
public enum Formatter {
  public static let valueClip = 120

  public static func line(_ n: SnapshotNode, geometry: Bool) -> String {
    let a = n.attributes
    var parts = ["\(n.id) " + String(repeating: "  ", count: n.depth) + a.role]
    if let t = a.title, !t.isEmpty { parts.append("\"\(clip(t))\"") }
    if let v = a.value, !v.isEmpty { parts.append("= \(clip(v))") }
    if a.focused { parts.append("[focused]") }
    if a.selected { parts.append("[selected]") }
    if !a.enabled && Role.isInteractive(a.role) { parts.append("[disabled]") }
    if !a.actions.isEmpty { parts.append("{" + a.actions.joined(separator: ",") + "}") }
    if geometry && a.geometryKnown { parts.append("@\(a.x),\(a.y) \(a.width)x\(a.height)") }
    return parts.joined(separator: " ")
  }

  public static func render(_ s: Snapshot, geometry: Bool) -> String {
    if s.nodes.isEmpty { return "(no elements)" }
    var lines = s.nodes.map { line($0, geometry: geometry) }
    if s.truncated { lines.append("… truncated: raise depth or maxElements, or use find") }
    return lines.joined(separator: "\n")
  }

  /// One URL or one paragraph of text must not flood the tree.
  static func clip(_ s: String) -> String {
    // Pure Swift on purpose: AXModel imports no frameworks, Foundation included.
    let flat = String(s.map { $0 == "\n" ? " " : $0 })
    return flat.count > valueClip ? String(flat.prefix(valueClip)) + "…" : flat
  }
}
