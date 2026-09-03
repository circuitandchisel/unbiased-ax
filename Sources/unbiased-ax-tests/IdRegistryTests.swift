import AXModel

func runIdRegistryTests() {
  print("IdRegistry")
  test("the same identity keeps the same id across snapshots") {
    var reg = IdRegistry()
    let a = reg.id(for: "elem-a")
    let b = reg.id(for: "elem-b")
    try expect(a != b)
    try expectEqual(reg.id(for: "elem-a"), a)
    try expectEqual(reg.id(for: "elem-b"), b)
  }
  test("ids are never reused, even after an element disappears") {
    var reg = IdRegistry()
    let a = reg.id(for: "gone")
    reg.retain(only: [])           // a snapshot in which nothing survived
    let c = reg.id(for: "new")
    try expect(c != a, "a dead element's id must not be handed to a new one")
  }
  test("retain drops identities not seen, so memory does not grow forever") {
    var reg = IdRegistry()
    _ = reg.id(for: "x"); _ = reg.id(for: "y"); _ = reg.id(for: "z")
    reg.retain(only: ["y"])
    try expectEqual(reg.count, 1)
  }
  test("ids start at 1 and read like line numbers") {
    var reg = IdRegistry()
    try expectEqual(reg.id(for: "first"), 1)
    try expectEqual(reg.id(for: "second"), 2)
  }
  test("an id looks up the identity it was given, and nothing after retain drops it") {
    var reg = IdRegistry()
    let id = reg.id(for: "btn")
    try expectEqual(reg.identity(for: id), AnyHashable("btn"))
    reg.retain(only: [])
    try expectEqual(reg.identity(for: id), nil)
  }
}
