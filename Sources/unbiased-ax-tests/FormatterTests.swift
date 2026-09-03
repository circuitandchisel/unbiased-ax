import AXModel

func runFormatterTests() {
  print("Formatter")
  func node(_ id: Int, _ depth: Int, _ a: Attributes) -> SnapshotNode { .init(id: id, depth: depth, attributes: a) }

  test("a line is id, role, quoted title, value, flags, actions") {
    let n = node(3, 2, Attributes(role: "text field", title: "Address and search bar",
                                  value: "youtube.com/", actions: ["press"], focused: true))
    try expectEqual(Formatter.line(n, geometry: false),
                    "3     text field \"Address and search bar\" = youtube.com/ [focused] {press}")
  }
  test("a bare structural element is just id and role") {
    try expectEqual(Formatter.line(node(2, 1, Attributes(role: "toolbar")), geometry: false), "2   toolbar")
  }
  test("geometry is appended only when asked") {
    let n = node(4, 1, Attributes(role: "button", title: "Reload", x: 10, y: 20, width: 30, height: 30, actions: ["press"]))
    try expectEqual(Formatter.line(n, geometry: true), "4   button \"Reload\" {press} @10,20 30x30")
    try expectEqual(Formatter.line(n, geometry: false), "4   button \"Reload\" {press}")
  }
  test("long values are clipped so one URL cannot flood the tree") {
    let long = String(repeating: "a", count: 500)
    let line = Formatter.line(node(1, 0, Attributes(role: "text field", value: long)), geometry: false)
    try expect(line.count < 200, "line was \(line.count) chars")
    try expect(line.contains("…"))
  }
  test("selected and disabled show as flags") {
    let n = node(6, 1, Attributes(role: "tab", title: "Loser", actions: ["press"], enabled: false, selected: true))
    try expectEqual(Formatter.line(n, geometry: false), "6   tab \"Loser\" [selected] [disabled] {press}")
  }
  test("geometry is omitted when unknown, even if asked for") {
    var a = Attributes(role: "application", title: "Finder"); a.geometryKnown = false
    try expectEqual(Formatter.line(node(1, 0, a), geometry: true), "1 application \"Finder\"")
  }
  test("an empty snapshot says so instead of returning nothing") {
    try expectEqual(Formatter.render(Snapshot(nodes: [], truncated: false), geometry: false), "(no elements)")
  }
  test("a whole snapshot joins lines and reports truncation on its own line") {
    let snap = Snapshot(nodes: [node(1, 0, Attributes(role: "window", title: "W"))], truncated: true)
    try expectEqual(Formatter.render(snap, geometry: false),
                    "1 window \"W\"\n… truncated: raise depth or maxElements, or use find")
  }
}
