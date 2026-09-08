import AXModel

func runFieldsTests() {
  print("fields (the settable controls, from the snapshot already held)")
  func call(_ d: Dispatcher, _ json: String) -> String { d.handle(line: json) }

  // Measured 2026-09-08, second Figma run: 34 of 90 turns were `find`s for the
  // id of an inspector field ("X-position" x5, "Width" x3, …) so the next click
  // could be aimed. The ids were in the snapshot the bridge already held.
  test("fields lists the value-bearing controls with id, role, title and value, and skips buttons") {
    let d = Dispatcher(backend: FakeBackend())
    _ = call(d, #"{"id":1,"method":"tree","params":{"app":"Brave Browser"}}"#)
    let out = call(d, #"{"id":2,"method":"fields","params":{"app":"Brave Browser"}}"#)
    try expect(out.contains(#""id":3"#) && out.contains(#""role":"text field""#) && out.contains(#""title":"Address""#) && out.contains(#""value":"a.com""#), out)
    try expect(!out.contains("OK") && !out.contains("Pad"), "buttons are not fields: \(out)")
    try expect(out.contains(#""truncated":false"#), out)
  }

  test("fields reflects the latest snapshot, whatever filter it was read with") {
    let b = FakeBackend()
    let d = Dispatcher(backend: b)
    _ = call(d, #"{"id":1,"method":"tree","params":{"app":"Brave Browser","interactive":true}}"#)
    _ = call(d, #"{"id":2,"method":"act","params":{"app":"Brave Browser","id":2,"action":"press"}}"#)
    // The values come from the snapshot the action settled on — no extra AX
    // traffic — so they are as fresh as the diff the caller just read.
    let out = call(d, #"{"id":9,"method":"fields","params":{"app":"Brave Browser"}}"#)
    try expect(out.contains(#""id":3,"role":"text field""#) && out.contains(#""value":"a.com""#), "the field is still there after an action: \(out)")
  }

  // Measured on Figma's live tree 2026-09-08: of 45 field-role controls, 14 were
  // pop up buttons that hold no value — Main menu, Multiplayer tools, the zoom
  // popup, blend mode, the style pickers. A menu trigger is pressed and picked
  // from, not written to, so it is not a field; every one of the other 31 was a
  // real settable control.
  test("a menu trigger is not a field: pop up and menu buttons are left out") {
    let b = FakeBackend()
    b.extraNodes = [FakeNode("w/menu", Attributes(role: "pop up button", title: "Main menu", value: "", width: 40, height: 20)),
                    FakeNode("w/sel", Attributes(role: "pop up button", title: "Blend mode", value: "Normal", width: 80, height: 20)),
                    FakeNode("w/empty", Attributes(role: "search field", title: "Search", value: "", width: 120, height: 20))]
    let d = Dispatcher(backend: b)
    _ = call(d, #"{"id":1,"method":"tree","params":{"app":"Brave Browser"}}"#)
    let out = call(d, #"{"id":2,"method":"fields","params":{"app":"Brave Browser","limit":100}}"#)
    try expect(!out.contains("Main menu") && !out.contains("Blend mode"), "a pop up button is a menu, not a field: \(out)")
    try expect(out.contains(#""title":"Search""#), "an EMPTY field is still a field to write into: \(out)")
  }

  test("fields on an app never read is an empty list, not an error") {
    let d = Dispatcher(backend: FakeBackend())
    let out = call(d, #"{"id":1,"method":"fields","params":{"app":"Brave Browser"}}"#)
    try expect(out.contains(#""fields":[]"#), out)
  }

  test("fields honours a limit and says when it cut") {
    let d = Dispatcher(backend: FakeBackend())
    _ = call(d, #"{"id":1,"method":"tree","params":{"app":"Brave Browser"}}"#)
    let out = call(d, #"{"id":2,"method":"fields","params":{"app":"Brave Browser","limit":0}}"#)
    try expect(out.contains(#""fields":[]"#) && out.contains(#""truncated":true"#), out)
  }
}
