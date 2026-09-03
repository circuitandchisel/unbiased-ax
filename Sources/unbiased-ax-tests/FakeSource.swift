import AXModel

/// A tree described by hand. Identity is the node's path string, which is
/// what makes "the same button across two snapshots" expressible in a test.
final class FakeNode {
  let path: String
  var attrs: Attributes
  var children: [FakeNode]
  init(_ path: String, _ attrs: Attributes, _ children: [FakeNode] = []) {
    self.path = path; self.attrs = attrs; self.children = children
  }
}

struct FakeSource: ElementSource {
  typealias Node = FakeNode
  func identity(of node: FakeNode) -> AnyHashable { node.path }
  func attributes(of node: FakeNode) -> Attributes? { node.attrs }
  func children(of node: FakeNode) -> [FakeNode] { node.children }
}

func button(_ path: String, _ title: String, w: Int = 80, h: Int = 24) -> FakeNode {
  FakeNode(path, Attributes(role: "button", title: title, width: w, height: h, actions: ["press"]))
}
func group(_ path: String, _ children: [FakeNode], title: String? = nil) -> FakeNode {
  FakeNode(path, Attributes(role: "group", title: title, width: 500, height: 300), children)
}
