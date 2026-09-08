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
