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

  /// The same node as data rather than as a line.
  ///
  /// Deliberately NOT sent alongside the text. A model reads the lines; a
  /// script reads this; sending both to a model that only reads one is paying
  /// twice for the same tree — and a run measured this afternoon billed 4.1M
  /// input tokens re-sending its context, so a second copy of every read is
  /// not a rounding error. Opt in with structured:true.
  ///
  /// `generation` is provenance, not a gate: it says which snapshot the id
  /// came from so a caller can tell how old its handle is. It does not make an
  /// older id invalid — re-resolution at use time decides that, and a handle
  /// that still names the same control is still good however old it is.
  public static func row(_ n: SnapshotNode, generation: Int, geometry: Bool) -> [String: Any] {
    let a = n.attributes
    var out: [String: Any] = [
      "id": n.id,
      "depth": n.depth,
      "role": a.role,
      "actions": a.actions,
      "enabled": a.enabled,
      "generation": generation,
    ]
    // Absent rather than null, and only what is true is stated. A tree where
    // every row carries "label": null and "selected": false is mostly noise,
    // and noise is what a script has to filter before it can see anything.
    if let t = a.title, !t.isEmpty { out["label"] = t }
    if let v = a.value, !v.isEmpty { out["value"] = v }
    if a.focused { out["focused"] = true }
    if a.selected { out["selected"] = true }
    if geometry && a.geometryKnown {
      out["frame"] = ["x": a.x, "y": a.y, "w": a.width, "h": a.height]
    }
    return out
  }

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
