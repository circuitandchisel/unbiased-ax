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
  test("a zero-size LEAF is dropped: nothing is there to see") {
    let hidden = FakeNode("w/h", Attributes(role: "button", title: "Ghost", width: 0, height: 0), [])
    let root = group("w", [hidden, button("w/ok", "OK")], title: "Save")
    var reg = IdRegistry()
    let snap = Snapshot.build(root: root, source: source, registry: &reg, options: .init())
    try expectEqual(snap.nodes.map(\.attributes.title), ["Save", "OK"])
  }
  test("a zero-size CONTAINER hoists its children instead of taking them with it") {
    // Figma reports its right-sidebar wrapper as 1470x0 with a real 241x885
    // panel inside. Dropping the subtree lost every inspector field in the
    // app — X, Y, W, H, opacity, every fill swatch — and a task spent 33
    // minutes concluding the panel was not exposed at all.
    let wrapper = FakeNode("w/side", Attributes(role: "group", title: "Right sidebar", width: 1470, height: 0),
                           [button("w/side/x", "X-position")])
    let root = group("w", [wrapper, button("w/ok", "OK")], title: "Save")
    var reg = IdRegistry()
    let snap = Snapshot.build(root: root, source: source, registry: &reg, options: .init())
    try expectEqual(snap.nodes.map(\.attributes.title), ["Save", "X-position", "OK"],
                    "the panel's contents survive; the wrapper itself says nothing and is not kept")
  }
  test("a genuinely hidden subtree still disappears, one node at a time") {
    // display:none reports zero for the children too, so each is dropped on
    // its own merits and the original rule's intent is preserved.
    let ghost = FakeNode("w/h", Attributes(role: "group", width: 0, height: 0),
                         [FakeNode("w/h/x", Attributes(role: "button", title: "X", width: 0, height: 0), [])])
    let root = group("w", [ghost, button("w/ok", "OK")], title: "Save")
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
  test("unknown geometry is not zero geometry: the application root has none and must not be dropped") {
    // Measured on real Finder and Brave: the tree came back with count 0,
    // because AXUIElementCreateApplication's element has no AXSize at all and
    // the size prune read "absent" as 0x0.
    var rootAttrs = Attributes(role: "application", title: "Finder", width: 0, height: 0)
    rootAttrs.geometryKnown = false
    let root = FakeNode("app", rootAttrs, [button("app/ok", "OK")])
    var reg = IdRegistry()
    let snap = Snapshot.build(root: root, source: source, registry: &reg, options: .init())
    try expectEqual(snap.nodes.map(\.attributes.title), ["Finder", "OK"])
  }
  test("a root that reports a known 0x0 is still the root — Finder does exactly this") {
    let root = FakeNode("app", Attributes(role: "application", title: "Finder", width: 0, height: 0), [button("app/ok", "OK")])
    var reg = IdRegistry()
    let snap = Snapshot.build(root: root, source: source, registry: &reg, options: .init())
    try expectEqual(snap.nodes.map(\.attributes.title), ["Finder", "OK"])
  }
  test("an element reachable by two paths appears once — Chromium's address bar did this") {
    // Measured: find returned id 651 twice at two depths. Same AX element, two
    // parents. The model must see one row per element or it double-counts.
    let shared = button("shared", "Address")
    let root = group("w", [group("w/a", [shared], title: "Toolbar"), group("w/b", [shared], title: "Focused")], title: "Win")
    var reg = IdRegistry()
    let snap = Snapshot.build(root: root, source: source, registry: &reg, options: .init())
    try expectEqual(snap.nodes.filter { $0.attributes.title == "Address" }.count, 1)
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
