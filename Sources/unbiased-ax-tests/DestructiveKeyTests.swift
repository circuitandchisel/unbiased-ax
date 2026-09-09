import AXModel

/// A frame with children, the way a design app's selection panel shows it.
private func frameNodes() -> [FakeNode] {
  [FakeNode("sel/frame", Attributes(role: "application group", title: "Unbiased, Design frame", width: 200, height: 40), [
    FakeNode("sel/frame/dim", Attributes(role: "term", title: "Dimensions", width: 100, height: 20)),
    FakeNode("sel/frame/val", Attributes(role: "text", value: "1024 1024", width: 100, height: 20)),
  ])]
}

func runDestructiveKeyTests() {
  print("Keys that destroy: digits at a non-field are refused, deletes are watched")
  func call(_ d: Dispatcher, _ json: String) -> String { d.handle(line: json) }

  // Measured twice, 2026-09-08: digits sent by key after a click that had not
  // focused the field went to a canvas, where they are shortcuts; shapes came
  // out at 28% and 40% opacity.
  test("a bare digit with keyboard focus off a field is refused, and nothing is sent") {
    let b = FakeBackend()
    b.focusedControlValue = (role: "web area", title: "Untitled")
    let d = Dispatcher(backend: b)
    _ = call(d, #"{"id":1,"method":"tree","params":{"app":"Brave Browser"}}"#)
    let out = call(d, #"{"id":2,"method":"key","params":{"app":"Brave Browser","key":"5","settle":false}}"#)
    try expect(out.contains("action_failed") && out.contains(#"web area \"Untitled\""#) && out.contains("shortcut"), out)
    try expect(out.contains("Nothing was sent") && out.contains("use type"), out)
    try expectEqual(b.keys.count, 0)
  }

  test("letters, digits with a modifier, digits aimed by id, and digits into a field all go through") {
    let b = FakeBackend()
    b.focusedControlValue = (role: "web area", title: "Untitled")
    let d = Dispatcher(backend: b)
    _ = call(d, #"{"id":1,"method":"tree","params":{"app":"Brave Browser"}}"#)
    for req in [#"{"id":2,"method":"key","params":{"app":"Brave Browser","key":"v"}}"#,
                #"{"id":3,"method":"key","params":{"app":"Brave Browser","key":"1","modifiers":["command"]}}"#,
                #"{"id":4,"method":"key","params":{"app":"Brave Browser","key":"5","id":3}}"#] {
      let out = call(d, req)
      try expect(out.contains(#""ok":true"#), out)
    }
    b.focusedControlValue = (role: "incrementor", title: "X-position")
    let out = call(d, #"{"id":5,"method":"key","params":{"app":"Brave Browser","key":"5"}}"#)
    try expect(out.contains(#""ok":true"#), out)
    try expectEqual(b.keys.count, 4)
  }

  // Measured 2026-09-08: return, delete, return, delete in one unwatched batch;
  // the second delete removed the frame the task lived in, and the caller
  // wrote "the frame is clean now".
  test("delete mid-sequence outside a text field is watched: its own diff, naming what went") {
    let b = FakeBackend()
    b.focusedControlValue = (role: "web area", title: "Untitled")
    b.extraNodes = frameNodes()
    let d = Dispatcher(backend: b)
    _ = call(d, #"{"id":1,"method":"tree","params":{"app":"Brave Browser"}}"#)
    b.keyRemovesExtra = true
    let out = call(d, #"{"id":2,"method":"key","params":{"app":"Brave Browser","key":"delete","settle":false}}"#)
    try expect(out.contains(#""watched""#) && out.contains("removes objects"), out)
    try expect(out.contains("- removed:") && out.contains(#"application group \"Unbiased, Design frame\""#), "names what went: \(out)")
    try expect(!out.contains(#""settled":false"#), out)
    try expectEqual(b.keys.count, 1)
  }

  test("the watched step leaves the baseline alone, so the closing read still shows the whole sequence") {
    let b = FakeBackend()
    b.focusedControlValue = (role: "web area", title: "Untitled")
    b.extraNodes = frameNodes()
    let d = Dispatcher(backend: b)
    _ = call(d, #"{"id":1,"method":"tree","params":{"app":"Brave Browser"}}"#)
    b.keyRemovesExtra = true
    _ = call(d, #"{"id":2,"method":"key","params":{"app":"Brave Browser","key":"delete","settle":false}}"#)
    let closing = call(d, #"{"id":3,"method":"tree","params":{"app":"Brave Browser"}}"#)
    try expect(closing.contains("- removed:"), "the closing diff must still carry the removal: \(closing)")
  }

  test("delete inside a text field is backspace: mid-sequence it stays unwatched") {
    let b = FakeBackend()
    b.focusedControlValue = (role: "text field", title: "Width")
    let d = Dispatcher(backend: b)
    _ = call(d, #"{"id":1,"method":"tree","params":{"app":"Brave Browser"}}"#)
    let before = b.snapshotCount
    let out = call(d, #"{"id":2,"method":"key","params":{"app":"Brave Browser","key":"delete","settle":false}}"#)
    try expect(out.contains(#""settled":false"#) && !out.contains("watched"), out)
    try expectEqual(b.snapshotCount, before)
  }

  test("a standalone delete names what it removed too") {
    let b = FakeBackend()
    b.focusedControlValue = (role: "web area", title: "Untitled")
    b.extraNodes = frameNodes()
    let d = Dispatcher(backend: b)
    _ = call(d, #"{"id":1,"method":"tree","params":{"app":"Brave Browser"}}"#)
    b.keyRemovesExtra = true
    let out = call(d, #"{"id":2,"method":"key","params":{"app":"Brave Browser","key":"delete"}}"#)
    try expect(out.contains("among them: application group") && !out.contains("watched"), out)
  }
}
