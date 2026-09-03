/// What changed between two snapshots of the same app, matched by stable id.
/// `~` changed, `+` added, removed summarized by id range. After the first
/// snapshot this is what callers get, and it is a fraction of the size.
public enum Differ {
  public static func render(from before: Snapshot, to after: Snapshot, geometry: Bool) -> String {
    let old = Dictionary(uniqueKeysWithValues: before.nodes.map { ($0.id, $0) })
    let new = Dictionary(uniqueKeysWithValues: after.nodes.map { ($0.id, $0) })
    var lines: [String] = []
    for n in after.nodes {
      if let o = old[n.id] {
        if o != n { lines.append("~" + Formatter.line(n, geometry: geometry)) }
      } else {
        lines.append("+" + Formatter.line(n, geometry: geometry))
      }
    }
    let removed = before.nodes.map(\.id).filter { new[$0] == nil }.sorted()
    if !removed.isEmpty { lines.append("- removed: " + ranges(removed)) }
    if after.truncated && !before.truncated { lines.append("… truncated") }
    return lines.isEmpty ? "(no changes)" : lines.joined(separator: "\n")
  }

  /// [2,3,4,9] -> "2-4, 9"
  static func ranges(_ ids: [Int]) -> String {
    var out: [String] = []
    var i = 0
    while i < ids.count {
      var j = i
      while j + 1 < ids.count && ids[j + 1] == ids[j] + 1 { j += 1 }
      out.append(i == j ? "\(ids[i])" : "\(ids[i])-\(ids[j])")
      i = j + 1
    }
    return out.joined(separator: ", ")
  }
}
