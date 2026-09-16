/// What changed between two snapshots of the same app, matched by stable id.
/// `~` changed, `+` added, removed summarized by id range. After the first
/// snapshot this is what callers get, and it is a fraction of the size.
public enum Differ {
  /// `nameRemoved`: how many removed nodes to name after the id range. Zero by
  /// default — a closing panel loses a hundred nodes nobody needs listed — and
  /// set for a step that DELETES things, where the names are the whole point:
  /// measured 2026-09-08, "- removed: 859-880" was the only trace of a frame
  /// going, and the caller read it as a clean frame.
  public static func render(from before: Snapshot, to after: Snapshot, geometry: Bool, nameRemoved: Int = 0) -> String {
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
    if !removed.isEmpty {
      var line = "- removed: " + ranges(removed)
      if nameRemoved > 0 {
        // Titled nodes first: a term or a plain text node says less than the
        // group that held them.
        let gone = before.nodes.filter { new[$0.id] == nil }
        let named = gone.filter { !($0.attributes.title ?? "").isEmpty } + gone.filter { ($0.attributes.title ?? "").isEmpty }
        let shown = named.prefix(nameRemoved).map { n -> String in
          let t = n.attributes.title.map { " \"\(Formatter.clip($0))\"" } ?? ""
          return "\(n.attributes.role)\(t)"
        }
        if !shown.isEmpty {
          line += ", among them: " + shown.joined(separator: "; ") + (gone.count > shown.count ? " and \(gone.count - shown.count) more" : "")
        }
      }
      lines.append(line)
    }
    if after.truncated && !before.truncated { lines.append("… truncated") }
    return lines.isEmpty ? "(no changes)" : lines.joined(separator: "\n")
  }

  /// Which elements differ between two snapshots — changed, added, or gone.
  ///
  /// Exists so an action can be judged by what it moved BESIDES its own
  /// target. Reading back the value you just wrote asks the accessibility
  /// layer to confirm itself, and when that layer is stale it agrees with its
  /// own stale answer. A panel that opened, a row that appeared, a button that
  /// became enabled — those are the app reacting, and the app is not the thing
  /// that lagged.
  public static func changedIds(from before: Snapshot, to after: Snapshot) -> Set<Int> {
    let old = Dictionary(uniqueKeysWithValues: before.nodes.map { ($0.id, $0) })
    let new = Dictionary(uniqueKeysWithValues: after.nodes.map { ($0.id, $0) })
    var out: Set<Int> = []
    for n in after.nodes where old[n.id] != n { out.insert(n.id) }
    for n in before.nodes where new[n.id] == nil { out.insert(n.id) }
    return out
  }

  /// Elements that APPEARED or VANISHED — structural change only, ignoring
  /// values that merely differ.
  ///
  /// This is the narrower question, and the useful one. "Did anything else
  /// change" is nearly always yes in a real app: a tab title carries a live
  /// memory counter, a clock ticks, a spinner spins. Measured against a
  /// browser, every action looked confirmed because something unrelated always
  /// moved. A panel opening, a menu appearing, a result rendering — those are
  /// the app responding, and they change the SHAPE of the tree rather than a
  /// number inside it.
  public static func structuralIds(from before: Snapshot, to after: Snapshot) -> Set<Int> {
    let old = Set(before.nodes.map(\.id))
    let new = Set(after.nodes.map(\.id))
    return new.subtracting(old).union(old.subtracting(new))
  }

  /// Whether anything changed at all, without building the text. Used to poll
  /// a just-acted-on app until it has reacted: rendering a diff only to check
  /// whether it says "(no changes)" would allocate a tree of strings per poll.
  public static func changed(from before: Snapshot, to after: Snapshot) -> Bool {
    if before.nodes.count != after.nodes.count { return true }
    let old = Dictionary(uniqueKeysWithValues: before.nodes.map { ($0.id, $0) })
    for n in after.nodes {
      guard let o = old[n.id] else { return true }
      if o != n { return true }
    }
    return false
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
