import AXModel

func runValuesTests() {
  print("values (read back a set of ids)")
  func call(_ d: Dispatcher, _ json: String) -> String { d.handle(line: json) }

  // Measured 2026-09-08: 32 finds in one Figma run existed to check fields a
  // batch had just written — a whole model turn each. Hand the values over.
  test("values returns each id's current value with its role and title") {
    let b = FakeBackend()
    let d = Dispatcher(backend: b)
    _ = call(d, #"{"id":1,"method":"tree","params":{"app":"Brave Browser"}}"#) // the Address field is id 3
    b.storedValues[3] = "b.com"
    let out = call(d, #"{"id":2,"method":"values","params":{"app":"Brave Browser","ids":[3]}}"#)
    try expect(out.contains(#""id":3"#) && out.contains(#""value":"b.com""#), out)
    try expect(out.contains(#""role":"text field""#) && out.contains(#""title":"Address""#), out)
  }

  test("an id the app never showed comes back with a null value, not an error") {
    let d = Dispatcher(backend: FakeBackend())
    _ = call(d, #"{"id":1,"method":"tree","params":{"app":"Brave Browser"}}"#)
    let out = call(d, #"{"id":2,"method":"values","params":{"app":"Brave Browser","ids":[999]}}"#)
    try expect(out.contains(#""result""#) && out.contains(#""value":null"#), out)
  }

  test("values needs ids, at most 40 of them") {
    let d = Dispatcher(backend: FakeBackend())
    let none = call(d, #"{"id":1,"method":"values","params":{"app":"Brave Browser"}}"#)
    try expect(none.contains("bad_params"), none)
    let ids = (1...41).map(String.init).joined(separator: ",")
    let many = call(d, "{\"id\":2,\"method\":\"values\",\"params\":{\"app\":\"Brave Browser\",\"ids\":[\(ids)]}}")
    try expect(many.contains("bad_params") && many.contains("40"), many)
  }
}
