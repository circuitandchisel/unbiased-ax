import AXModel

/// `verify` — the caller states what success looks like, and the bridge says
/// whether that is true, false, or beyond what it can prove.
///
/// The point of the third value is that the first two are not enough. A driver
/// that can only say yes or no has to guess when it cannot tell, and a guess
/// here reads as success — which is how an action nobody proved becomes an
/// action everybody believes.
func runPostconditionTests() {
  print("Postconditions")
  func call(_ d: Dispatcher, _ json: String) -> String { d.handle(line: json) }
  let read = #"{"id":1,"method":"tree","params":{"app":"Brave Browser"}}"#

  test("an element that is there, with the value asked for, is satisfied") {
    let d = Dispatcher(backend: FakeBackend())
    _ = call(d, read)
    let out = call(d, #"{"id":2,"method":"verify","params":{"app":"Brave Browser","role":"text field","label":"Address","expect":{"value":"a.com"}}}"#)
    try expect(out.contains(#""verdict":"satisfied""#), out)
  }

  test("a value that never arrives is unsatisfied — a real answer, not a timeout") {
    let d = Dispatcher(backend: FakeBackend())
    _ = call(d, read)
    let out = call(d, #"{"id":3,"method":"verify","params":{"app":"Brave Browser","role":"text field","label":"Address","expect":{"value":"never"},"timeoutMs":0}}"#)
    try expect(out.contains(#""verdict":"unsatisfied""#), out)
  }

  test("a state the element does not expose is unknown, and unknown says it is not success") {
    // No flags on this backend: the element lists no AXExpanded at all. The
    // wrong answer here is "false" — which is exactly what a raw value read
    // would have given, and what would send a caller pressing again.
    let d = Dispatcher(backend: FakeBackend())
    _ = call(d, read)
    let out = call(d, #"{"id":4,"method":"verify","params":{"app":"Brave Browser","role":"text field","label":"Address","expect":{"expanded":true},"timeoutMs":0}}"#)
    try expect(out.contains(#""verdict":"unknown""#), out)
    try expect(out.contains("NOT success"), out)
  }

  test("several matches is unknown: looking again returns the same several") {
    let b = FakeBackend(); b.twoOKs = true
    let d = Dispatcher(backend: b)
    _ = call(d, read)
    let out = call(d, #"{"id":5,"method":"verify","params":{"app":"Brave Browser","label":"OK","expect":{"exists":true},"timeoutMs":0}}"#)
    try expect(out.contains(#""verdict":"unknown""#), out)
    try expect(out.contains("NOT success"), out)
  }

  test("when the element DOES expose the state, the answer is the state — both ways") {
    let b = FakeBackend()
    b.flags[3] = ["AXExpanded": false]
    let d = Dispatcher(backend: b)
    _ = call(d, read)
    let closed = call(d, #"{"id":6,"method":"verify","params":{"app":"Brave Browser","role":"text field","label":"Address","expect":{"expanded":false}}}"#)
    try expect(closed.contains(#""verdict":"satisfied""#), closed)
    let open = call(d, #"{"id":7,"method":"verify","params":{"app":"Brave Browser","role":"text field","label":"Address","expect":{"expanded":true},"timeoutMs":0}}"#)
    try expect(open.contains(#""verdict":"unsatisfied""#), open)
  }

  test("expecting something to be GONE is satisfied when nothing matches") {
    let d = Dispatcher(backend: FakeBackend())
    _ = call(d, read)
    let out = call(d, #"{"id":8,"method":"verify","params":{"app":"Brave Browser","label":"No Such Thing","expect":{"exists":false}}}"#)
    try expect(out.contains(#""verdict":"satisfied""#), out)
  }

  test("an action on a toggle that proved nothing warns against sending it again") {
    // The measured failure: press an accordion, read nothing, press again,
    // close what the first press opened. The bridge does not retry and does
    // not decide — it says what the control is.
    let b = FakeBackend()
    b.flags[3] = ["AXExpanded": true]
    let d = Dispatcher(backend: b)
    _ = call(d, read)
    let out = call(d, #"{"id":9,"method":"act","params":{"app":"Brave Browser","id":3,"action":"press"}}"#)
    try expect(out.contains(#""toggle":true"#), out)
    try expect(out.contains("UNDO"), out)
  }

  test("a control with no open/closed state gets no toggle warning") {
    let d = Dispatcher(backend: FakeBackend())
    _ = call(d, read)
    let out = call(d, #"{"id":10,"method":"act","params":{"app":"Brave Browser","id":3,"action":"press"}}"#)
    try expect(!out.contains(#""toggle":true"#), out)
  }
}
