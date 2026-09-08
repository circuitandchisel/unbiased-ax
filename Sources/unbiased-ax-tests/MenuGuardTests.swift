import AXModel

/// A menu bar item with its menu open, the way the tree shows it: the item is
/// selected and a `menu` with items hangs beneath it.
private func openMenuNodes(_ name: String) -> [FakeNode] {
  var bar = Attributes(role: "menu bar item", title: name, width: 40, height: 22, actions: ["cancel", "press", "pick"])
  bar.selected = true
  let items = [FakeNode("mb/\(name)/undo", Attributes(role: "menu item", title: "Undo", width: 200, height: 20, actions: ["press"])),
               FakeNode("mb/\(name)/redo", Attributes(role: "menu item", title: "Redo", width: 200, height: 20, actions: ["press"]))]
  let menu = FakeNode("mb/\(name)/menu", Attributes(role: "menu", title: name, width: 200, height: 60), items)
  return [FakeNode("mb/\(name)", bar, [menu])]
}

func runMenuGuardTests() {
  print("An open menu intercepts pointer input; say so before and after")
  func call(_ d: Dispatcher, _ json: String) -> String { d.handle(line: json) }

  // Measured 2026-09-08: a press opened a menu, and every drag for the next
  // ten minutes did nothing but dismiss it — 13 changed lines, all `menu bar
  // item`, eight times in a row — while the caller theorised about displays.
  test("a pointer gesture while a menu is open is refused, naming the menu") {
    let b = FakeBackend()
    b.extraNodes = openMenuNodes("Edit")
    let d = Dispatcher(backend: b)
    _ = call(d, #"{"id":1,"method":"tree","params":{"app":"Brave Browser"}}"#)
    let out = call(d, #"{"id":2,"method":"pointer","params":{"app":"Brave Browser","id":2}}"#)
    try expect(out.contains("action_failed") && out.contains("menu is open") && out.contains("Edit"), out)
    try expect(out.contains("Nothing was clicked") && out.contains("escape"), out)
    try expectEqual(b.pointerCalls.count, 0)
  }

  test("the refusal is decided on a fresh look, so a menu that has since closed does not block") {
    let b = FakeBackend()
    b.extraNodes = openMenuNodes("Edit")
    let d = Dispatcher(backend: b)
    _ = call(d, #"{"id":1,"method":"tree","params":{"app":"Brave Browser"}}"#) // last read saw the menu open
    b.extraNodes = [] // the user (or an escape nobody told us about) closed it
    let out = call(d, #"{"id":2,"method":"pointer","params":{"app":"Brave Browser","id":2}}"#)
    try expect(out.contains(#""ok":true"#), out)
    try expectEqual(b.pointerCalls.count, 1)
  }

  test("an action whose only effect was closing a menu says so at the top of its diff") {
    let b = FakeBackend()
    b.extraNodes = openMenuNodes("Edit")
    let d = Dispatcher(backend: b)
    _ = call(d, #"{"id":1,"method":"tree","params":{"app":"Brave Browser"}}"#)
    b.extraNodes = [] // the press lands on the app, and the menu goes away — nothing else moves
    let out = call(d, #"{"id":2,"method":"act","params":{"app":"Brave Browser","id":2,"action":"press"}}"#)
    try expect(out.contains("dismissed an open menu") && out.contains("removed"), out)
  }

  test("an action that changed something besides the menu is reported as what it did") {
    let b = FakeBackend()
    b.extraNodes = openMenuNodes("Edit")
    let d = Dispatcher(backend: b)
    _ = call(d, #"{"id":1,"method":"tree","params":{"app":"Brave Browser"}}"#)
    b.extraNodes = []
    b.snapshotsUntilChange = b.snapshotCount // the late "Result" button appears as well
    let out = call(d, #"{"id":2,"method":"act","params":{"app":"Brave Browser","id":2,"action":"press"}}"#)
    try expect(out.contains("Result") && !out.contains("dismissed an open menu"), out)
  }

  test("with no menu open nothing changes: pointer proceeds and diffs are untouched") {
    let b = FakeBackend()
    let d = Dispatcher(backend: b)
    _ = call(d, #"{"id":1,"method":"tree","params":{"app":"Brave Browser"}}"#)
    let out = call(d, #"{"id":2,"method":"pointer","params":{"app":"Brave Browser","id":2}}"#)
    try expect(out.contains(#""ok":true"#) && !out.contains("menu"), out)
  }
}
