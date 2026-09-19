/// A structured description of ONE element, and the rules for resolving it.
///
/// The point is to let a caller say what it means — "the enabled Billing tab
/// inside Workspace settings" — instead of holding a number it read three
/// turns ago. A selector can be resolved again immediately before acting, so
/// the gap between deciding and doing shrinks to nothing.
///
/// Matching is exact by default and never fuzzy. A near-miss that silently
/// resolves to something is the failure this exists to prevent: it acts on a
/// control the caller never saw, and reports success.
public struct Selector {
  public var role: String?
  public var label: String?
  public var value: String?
  /// An action the element must offer, e.g. "press". Useful for separating a
  /// control from the static text that labels it.
  public var action: String?
  public var enabled: Bool?
  public var selected: Bool?
  /// Restrict to descendants of this element. Our snapshot is a flat list with
  /// a depth, so an ancestor is the nearest preceding node at a lower depth —
  /// which makes scoping cheap and makes "unique" achievable in a tree where
  /// the same label appears in four panels.
  public var within: Int?
  /// Substring instead of equality, for label and value. Off by default:
  /// "Save" matching "Save as…" is how the wrong button gets pressed.
  public var contains: Bool = false
  /// Ignore case on label and value. Off by default for the same reason.
  public var caseInsensitive: Bool = false

  public init(role: String? = nil, label: String? = nil, value: String? = nil, action: String? = nil,
              enabled: Bool? = nil, selected: Bool? = nil, within: Int? = nil,
              contains: Bool = false, caseInsensitive: Bool = false) {
    self.role = role; self.label = label; self.value = value; self.action = action
    self.enabled = enabled; self.selected = selected; self.within = within
    self.contains = contains; self.caseInsensitive = caseInsensitive
  }

  public var isEmpty: Bool {
    role == nil && label == nil && value == nil && action == nil && enabled == nil && selected == nil
  }
}

/// What resolving a selector produced. Exactly three outcomes, and no fourth:
/// there is no "best match", because a best match is a guess wearing the
/// clothes of an answer.
public enum Resolution {
  case one(SnapshotNode)
  /// Nothing matched. Carries what ALMOST did — same label but a different
  /// role, same role but a different label — so the caller can correct the
  /// selector instead of guessing at it again.
  case none(near: [SnapshotNode])
  /// Several matched. Carries all of them, so the caller can see what
  /// distinguishes them and say which it meant. Reading again does not help
  /// with this one; it produces the same several.
  case many([SnapshotNode])
}

public enum SelectorEngine {
  /// Descendants of `within`, using depth: every node after it, up to the next
  /// node at the same depth or shallower.
  public static func scope(_ nodes: [SnapshotNode], within: Int?) -> [SnapshotNode] {
    guard let within, let start = nodes.firstIndex(where: { $0.id == within }) else { return nodes }
    let depth = nodes[start].depth
    var out: [SnapshotNode] = []
    for n in nodes[(start + 1)...] {
      if n.depth <= depth { break }
      out.append(n)
    }
    return out
  }

  static func text(_ have: String?, _ want: String, _ s: Selector) -> Bool {
    guard let have else { return false }
    let a = s.caseInsensitive ? have.lowercased() : have
    let b = s.caseInsensitive ? want.lowercased() : want
    return s.contains ? a.contains(b) : a == b
  }

  public static func matches(_ n: SnapshotNode, _ s: Selector) -> Bool {
    let a = n.attributes
    if let role = s.role, a.role != role { return false }
    if let label = s.label, !text(a.title, label, s) { return false }
    if let value = s.value, !text(a.value, value, s) { return false }
    if let action = s.action, !a.actions.contains(action) { return false }
    if let enabled = s.enabled, a.enabled != enabled { return false }
    if let selected = s.selected, a.selected != selected { return false }
    return true
  }

  /// Elements that match all but ONE of the stated criteria — the ones a
  /// caller most likely meant. Capped, because a long list of near-misses is
  /// another way of saying nothing.
  public static func near(_ nodes: [SnapshotNode], _ s: Selector, limit: Int = 5) -> [SnapshotNode] {
    var out: [SnapshotNode] = []
    for n in nodes {
      var missed = 0
      let a = n.attributes
      if let role = s.role, a.role != role { missed += 1 }
      if let label = s.label, !text(a.title, label, s) { missed += 1 }
      if let value = s.value, !text(a.value, value, s) { missed += 1 }
      if let action = s.action, !a.actions.contains(action) { missed += 1 }
      if let enabled = s.enabled, a.enabled != enabled { missed += 1 }
      if let selected = s.selected, a.selected != selected { missed += 1 }
      if missed == 1 { out.append(n) }
      if out.count >= limit { break }
    }
    return out
  }

  public static func resolve(_ nodes: [SnapshotNode], _ s: Selector) -> Resolution {
    let scoped = scope(nodes, within: s.within)
    let hits = scoped.filter { matches($0, s) }
    if hits.count == 1 { return .one(hits[0]) }
    if hits.isEmpty { return .none(near: near(scoped, s)) }
    return .many(hits)
  }
}
