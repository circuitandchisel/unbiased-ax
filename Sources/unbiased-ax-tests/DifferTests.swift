import AXModel

func runDifferTests() {
  print("Differ")
  func node(_ id: Int, _ depth: Int, _ a: Attributes) -> SnapshotNode { .init(id: id, depth: depth, attributes: a) }
  let win = node(1, 0, Attributes(role: "window", title: "YouTube - Brave", actions: ["raise"]))

  test("nothing changed renders as exactly that") {
    let s = Snapshot(nodes: [win], truncated: false)
    try expectEqual(Differ.render(from: s, to: s, geometry: false), "(no changes)")
  }
  test("a changed attribute is a ~ line, unchanged elements are omitted") {
    let before = Snapshot(nodes: [win, node(2, 1, Attributes(role: "tab", title: "Home", actions: ["press"]))], truncated: false)
    let after  = Snapshot(nodes: [win, node(2, 1, Attributes(role: "tab", title: "Home", actions: ["press"], selected: true))], truncated: false)
    try expectEqual(Differ.render(from: before, to: after, geometry: false), "~2   tab \"Home\" [selected] {press}")
  }
  test("a new element is a + line") {
    let before = Snapshot(nodes: [win], truncated: false)
    let after  = Snapshot(nodes: [win, node(3, 1, Attributes(role: "button", title: "Play", actions: ["press"]))], truncated: false)
    try expectEqual(Differ.render(from: before, to: after, geometry: false), "+3   button \"Play\" {press}")
  }
  test("removed elements are summarized by id, not re-listed") {
    let before = Snapshot(nodes: [win, node(2, 1, Attributes(role: "tab", title: "A")),
                                  node(3, 1, Attributes(role: "tab", title: "B")),
                                  node(4, 1, Attributes(role: "tab", title: "C")),
                                  node(9, 1, Attributes(role: "tab", title: "D"))], truncated: false)
    let after  = Snapshot(nodes: [win], truncated: false)
    try expectEqual(Differ.render(from: before, to: after, geometry: false), "- removed: 2-4, 9")
  }
  test("a window title change is a ~ on the window") {
    let after = Snapshot(nodes: [node(1, 0, Attributes(role: "window", title: "Loser - Audio playing - Brave", actions: ["raise"]))], truncated: false)
    let out = Differ.render(from: Snapshot(nodes: [win], truncated: false), to: after, geometry: false)
    try expect(out.hasPrefix("~1 window \"Loser - Audio playing - Brave\""), out)
  }
}
