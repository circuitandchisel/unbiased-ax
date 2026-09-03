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
      // Never prune the root: the caller asked for exactly this element, and
      // Finder's application element reports a KNOWN 0x0 (measured).
      if depth > 0 && attrs.geometryKnown && (attrs.width == 0 || attrs.height == 0) { return }

      let structural = !Role.isInteractive(attrs.role)
      let untitled = (attrs.title ?? "").isEmpty && (attrs.value ?? "").isEmpty
      let kids = source.children(of: node)

      // Hoist: an untitled container with children says nothing itself.
      if structural && untitled && !kids.isEmpty && depth > 0 {
        for k in kids { visit(k, depth: depth) }
        return
      }
      if options.interactiveOnly && structural && kids.isEmpty && depth > 0 { return }

      let identity = source.identity(of: node)
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
