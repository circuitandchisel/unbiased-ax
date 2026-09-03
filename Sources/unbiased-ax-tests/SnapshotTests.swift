import AXModel

func runSnapshotTests() {
  print("Snapshot")
  let source = FakeSource()

  test("an untitled group is hoisted: its children take its place") {
    let root = group("w", [group("w/g", [button("w/g/ok", "OK"), button("w/g/cancel", "Cancel")])], title: "Save")
    var reg = IdRegistry()
    let snap = Snapshot.build(root: root, source: source, registry: &reg, options: .init())
    try expectEqual(snap.nodes.map(\.attributes.title), ["Save", "OK", "Cancel"])
    try expectEqual(snap.nodes.map(\.depth), [0, 1, 1], "hoisted children sit at the group's depth")
  }
  test("a titled group is kept: the title is information") {
    let root = group("w", [group("w/g", [button("w/g/ok", "OK")], title: "Actions")], title: "Save")
    var reg = IdRegistry()
    let snap = Snapshot.build(root: root, source: source, registry: &reg, options: .init())
    try expectEqual(snap.nodes.map(\.attributes.title), ["Save", "Actions", "OK"])
  }
  test("zero-size elements are dropped along with their subtree") {
    let hidden = FakeNode("w/h", Attributes(role: "group", width: 0, height: 0), [button("w/h/x", "X")])
    let root = group("w", [hidden, button("w/ok", "OK")], title: "Save")
    var reg = IdRegistry()
    let snap = Snapshot.build(root: root, source: source, registry: &reg, options: .init())
    try expectEqual(snap.nodes.map(\.attributes.title), ["Save", "OK"])
  }
  test("depth is capped and the snapshot says so") {
    var deep = button("leaf", "Leaf")
    for i in (0..<20).reversed() { deep = group("g\(i)", [deep], title: "L\(i)") }
    var reg = IdRegistry()
    let snap = Snapshot.build(root: deep, source: source, registry: &reg, options: .init(maxDepth: 5))
    try expect(snap.nodes.count <= 6, "got \(snap.nodes.count) nodes")
    try expect(snap.truncated, "must report truncation")
  }
  test("element count is capped and the snapshot says so") {
    let many = (0..<200).map { button("w/b\($0)", "B\($0)") }
    var reg = IdRegistry()
    let snap = Snapshot.build(root: group("w", many, title: "W"), source: source, registry: &reg,
                              options: .init(maxElements: 50))
    try expectEqual(snap.nodes.count, 50)
    try expect(snap.truncated)
  }
  test("the same element keeps its id across two snapshots") {
    let root = group("w", [button("w/ok", "OK"), button("w/cancel", "Cancel")], title: "Save")
    var reg = IdRegistry()
    let first = Snapshot.build(root: root, source: source, registry: &reg, options: .init())
    let okId = first.nodes.first { $0.attributes.title == "OK" }!.id
    root.children.insert(button("w/new", "New"), at: 0)      // something else appeared
    let second = Snapshot.build(root: root, source: source, registry: &reg, options: .init())
    try expectEqual(second.nodes.first { $0.attributes.title == "OK" }!.id, okId)
  }
  test("interactive-only mode keeps windows and controls, drops decoration") {
    let root = group("w", [FakeNode("w/t", Attributes(role: "text", title: "Hello", width: 50, height: 12)),
                           button("w/ok", "OK")], title: "Save")
    root.attrs.role = "standard window"
    var reg = IdRegistry()
    let snap = Snapshot.build(root: root, source: source, registry: &reg, options: .init(interactiveOnly: true))
    try expectEqual(snap.nodes.map(\.attributes.title), ["Save", "OK"])
  }
}
