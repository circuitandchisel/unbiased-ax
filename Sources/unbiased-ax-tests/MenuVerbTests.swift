import AXModel

func runMenuVerbTests() {
  print("Menu commands by name: list them, run one, never guess a shortcut")
  func call(_ d: Dispatcher, _ json: String) -> String { d.handle(line: json) }

  // Measured 2026-09-09: told to hide the app's panels before drawing, the
  // model pressed Tab — the shortcut for that in some other design app — and
  // the floating toolbar it meant to avoid ended its path at point 43. The
  // command it wanted was in the menu bar the whole time: View > Show/Hide UI,
  // ⌘\. A closed menu bar enumerates 420 items on that app, with shortcuts,
  // and a closed item presses fine once the app is active.
  test("menus with no query lists the top-level menus and how many commands there are") {
    let d = Dispatcher(backend: FakeBackend())
    let out = call(d, #"{"id":1,"method":"menus","params":{"app":"Brave Browser"}}"#)
    try expect(out.contains(#""menus":["View","Edit","Object"]"#), out)
    try expect(out.contains(#""count":5"#) && out.contains("query"), "says how many and how to narrow: \(out)")
  }

  test("menus with a query lists matching commands with their menu, path and shortcut") {
    let d = Dispatcher(backend: FakeBackend())
    let out = call(d, #"{"id":1,"method":"menus","params":{"app":"Brave Browser","query":"hide"}}"#)
    // JSON escapes the slash: the line arrives as `Show\/Hide UI`.
    try expect(out.contains(#"View > Show\/Hide UI  ⌘\\"#), out)
    try expect(!out.contains("Duplicate"), "only what matched: \(out)")
    let dis = call(d, #"{"id":2,"method":"menus","params":{"app":"Brave Browser","query":"tile"}}"#)
    try expect(dis.contains("(disabled)"), dis)
  }

  test("menu runs a command by its title, activating the app, and reports the diff") {
    let b = FakeBackend()
    let d = Dispatcher(backend: b)
    _ = call(d, #"{"id":1,"method":"tree","params":{"app":"Brave Browser"}}"#)
    let out = call(d, #"{"id":2,"method":"menu","params":{"app":"Brave Browser","item":"show/hide ui"}}"#)
    try expect(out.contains(#""ok":true"#) && out.contains(#""diff""#), out)
    try expectEqual(b.pressedMenus, [["View", "Show/Hide UI"]])
    try expect(out.contains(#""ran":"View > Show\/Hide UI""#), "says exactly what ran: \(out)")
  }

  test("a title that lives in two menus is refused until the path says which") {
    let b = FakeBackend()
    let d = Dispatcher(backend: b)
    let out = call(d, #"{"id":1,"method":"menu","params":{"app":"Brave Browser","item":"Duplicate"}}"#)
    try expect(out.contains("bad_params") && out.contains("Edit > Duplicate") && out.contains("Object > Duplicate"), out)
    try expectEqual(b.pressedMenus.count, 0)
    let ok = call(d, #"{"id":2,"method":"menu","params":{"app":"Brave Browser","item":"Object > Duplicate"}}"#)
    try expect(ok.contains(#""ok":true"#), ok)
    try expectEqual(b.pressedMenus, [["Object", "Duplicate"]])
  }

  test("a disabled command is refused, and an unknown one gets the nearest names") {
    let b = FakeBackend()
    let d = Dispatcher(backend: b)
    let dis = call(d, #"{"id":1,"method":"menu","params":{"app":"Brave Browser","item":"Full Screen Tile"}}"#)
    try expect(dis.contains("action_failed") && dis.contains("disabled"), dis)
    let unk = call(d, #"{"id":2,"method":"menu","params":{"app":"Brave Browser","item":"Hide"}}"#)
    try expect(unk.contains("bad_params") && unk.contains(#"Show\/Hide UI"#), "offers the near miss: \(unk)")
    let none = call(d, #"{"id":3,"method":"menu","params":{"app":"Brave Browser","item":"Frobnicate"}}"#)
    try expect(none.contains("bad_params") && none.contains("menus"), "points at the listing: \(none)")
    try expectEqual(b.pressedMenus.count, 0)
  }
}
