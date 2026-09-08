/// How a tree is read. The live adapter implements this over AXUIElement; the
/// tests implement it over a hand-built tree. Nothing else may read elements.
public protocol ElementSource {
  associatedtype Node
  func identity(of node: Node) -> AnyHashable
  /// nil means the element vanished between listing and reading; skip it.
  func attributes(of node: Node) -> Attributes?
  func children(of node: Node) -> [Node]
}

public struct SnapshotNode: Equatable {
  public var id: Int
  public var depth: Int
  public var attributes: Attributes
  public init(id: Int, depth: Int, attributes: Attributes) { self.id = id; self.depth = depth; self.attributes = attributes }
}

public struct SnapshotOptions {
  public var maxDepth: Int
  public var maxElements: Int
  public var interactiveOnly: Bool
  /// Ask Chromium to build its web-content tree (AXEnhancedUserInterface).
  /// Opt-in: it makes the browser do measurable extra work for every page.
  public var webContent: Bool
  public init(maxDepth: Int = 14, maxElements: Int = 1500, interactiveOnly: Bool = false, webContent: Bool = false) {
    self.maxDepth = maxDepth; self.maxElements = maxElements; self.interactiveOnly = interactiveOnly; self.webContent = webContent
  }
}

public struct Snapshot: Equatable {
  public var nodes: [SnapshotNode]
  public var truncated: Bool
  public init(nodes: [SnapshotNode], truncated: Bool) { self.nodes = nodes; self.truncated = truncated }

  /// Depth-first, in reading order. Pruning rules, each measured against real
  /// trees rather than guessed:
  ///  - KNOWN zero-size elements and their subtrees are invisible: dropped. An
  ///    element with no geometry at all (the application root) is kept.
  ///  - an untitled structural container carries no information: its children
  ///    are hoisted to its depth. Chromium nests a dozen of these per control.
  ///  - interactiveOnly additionally drops structural leaves (text, images).
  public static func build<S: ElementSource>(root: S.Node, source: S, registry: inout IdRegistry,
                                             options: SnapshotOptions) -> Snapshot {
    var nodes: [SnapshotNode] = []
    var seen = Set<AnyHashable>()
    var truncated = false

    func visit(_ node: S.Node, depth: Int) {
      if nodes.count >= options.maxElements { truncated = true; return }
      guard let attrs = source.attributes(of: node) else { return }
      let kids = source.children(of: node)
      // Never prune the root: the caller asked for exactly this element, and
      // Finder's application element reports a KNOWN 0x0 (measured).
      //
      // A zero dimension means invisible only for a LEAF. A container that
      // reports zero and still has children is a layout wrapper, and dropping
      // its subtree loses everything inside it: measured in Figma, the group
      // labelled "Right sidebar" reports 1470x0 while its child panel is a
      // real 241x885 — so the entire inspector (X, Y, W, H, opacity, every
      // fill swatch, all of it) was missing from every tree we ever took of
      // that app, while "Left sidebar" at 57x885 came through fine. One task
      // spent 33 minutes concluding the panel "isn't exposed in the
      // accessibility tree" and hunting through menus for it.
      //
      // So hoist through it instead. Anything genuinely hidden reports zero
      // for its own children too, and each of those is dropped on its own
      // merits one level down — which keeps the original rule's intent without
      // taking a real subtree with it. The check must run AFTER children are
      // fetched, and before the depth check, which is why raising `depth`
      // never recovered any of this.
      if depth > 0 && attrs.geometryKnown && (attrs.width == 0 || attrs.height == 0) {
        if kids.isEmpty { return }
        for k in kids { visit(k, depth: depth) }
        return
      }

      let structural = !Role.isInteractive(attrs.role)
      let untitled = (attrs.title ?? "").isEmpty && (attrs.value ?? "").isEmpty

      // Hoist: an untitled container with children says nothing itself.
      if structural && untitled && !kids.isEmpty && depth > 0 {
        for k in kids { visit(k, depth: depth) }
        return
      }
      if options.interactiveOnly && structural && kids.isEmpty && depth > 0 { return }

      let identity = source.identity(of: node)
      // The same element can hang off two parents (Chromium does this with its
      // address bar). One row per element, at the first place it was met.
      if seen.contains(identity) { return }
      seen.insert(identity)
      nodes.append(SnapshotNode(id: registry.id(for: identity), depth: depth, attributes: attrs))

      if depth + 1 > options.maxDepth {
        if !kids.isEmpty { truncated = true }
        return
      }
      for k in kids { visit(k, depth: depth + 1) }
    }

    visit(root, depth: 0)
    registry.retain(only: seen)
    return Snapshot(nodes: nodes, truncated: truncated)
  }
}
