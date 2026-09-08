import AXModel

func runBaselineTests() {
  print("Baselines (one per filter)")
  func call(_ d: Dispatcher, _ json: String) -> String { d.handle(line: json) }

  // Measured 2026-09-08 on the Figma logo run: 28 web/interactive flips between
  // consecutive reads, each of which forced the app to ask for the whole tree
  // (~9KB), and the two compactions that followed cost nine minutes. A flip is
  // not a reason to resend everything: diff against that filter's own last read.
  test("a read under a new filter is a full tree; a read under a seen filter is a diff") {
    let d = Dispatcher(backend: FakeBackend())
    let a1 = call(d, #"{"id":1,"method":"tree","params":{"app":"Brave Browser"}}"#)
    try expect(a1.contains(#""tree":"#), a1)
    let b1 = call(d, #"{"id":2,"method":"tree","params":{"app":"Brave Browser","interactive":true}}"#)
    try expect(b1.contains(#""tree":"#), "first read under interactive:true has no baseline of its own: \(b1)")
    let a2 = call(d, #"{"id":3,"method":"tree","params":{"app":"Brave Browser"}}"#)
    try expect(a2.contains(#""diff":"(no changes)""#), "the default filter's baseline must survive a read under another filter: \(a2)")
    let b2 = call(d, #"{"id":4,"method":"tree","params":{"app":"Brave Browser","interactive":true}}"#)
    try expect(b2.contains(#""diff":"(no changes)""#), b2)
  }

  test("a change is reported once per filter, against that filter's own last read") {
    let b = FakeBackend()
    let d = Dispatcher(backend: b)
    _ = call(d, #"{"id":1,"method":"tree","params":{"app":"Brave Browser"}}"#)
    _ = call(d, #"{"id":2,"method":"tree","params":{"app":"Brave Browser","interactive":true}}"#)
    b.snapshotsUntilChange = b.snapshotCount // every snapshot from here on carries the late "Result" button
    let a = call(d, #"{"id":3,"method":"tree","params":{"app":"Brave Browser"}}"#)
    try expect(a.contains("Result"), "the default filter sees the new node: \(a)")
    let bRead = call(d, #"{"id":4,"method":"tree","params":{"app":"Brave Browser","interactive":true}}"#)
    try expect(bRead.contains("Result"), "the other filter has not seen it yet either, so it too reports it: \(bRead)")
    let again = call(d, #"{"id":5,"method":"tree","params":{"app":"Brave Browser","interactive":true}}"#)
    try expect(again.contains(#""diff":"(no changes)""#), again)
  }

  test("an id seen under one filter can be acted on after a read under another") {
    let b = FakeBackend()
    let d = Dispatcher(backend: b)
    // depth:0 shows only the window; the default read shows the OK button (id 2).
    _ = call(d, #"{"id":1,"method":"tree","params":{"app":"Brave Browser","depth":0}}"#)
    let full = call(d, #"{"id":2,"method":"tree","params":{"app":"Brave Browser"}}"#)
    try expect(full.contains(#"2   button \"OK\""#), full)
    _ = call(d, #"{"id":3,"method":"tree","params":{"app":"Brave Browser","depth":0}}"#)
    let out = call(d, #"{"id":4,"method":"act","params":{"app":"Brave Browser","id":2,"action":"press"}}"#)
    try expect(out.contains(#""ok":true"#), "id 2 is in the registry and was seen under the default filter: \(out)")
    try expectEqual(b.acted.count, 1)
  }

  test("an action updates the baseline of the filter it ran with, and only that one") {
    let b = FakeBackend()
    let d = Dispatcher(backend: b)
    _ = call(d, #"{"id":1,"method":"tree","params":{"app":"Brave Browser"}}"#)
    _ = call(d, #"{"id":2,"method":"tree","params":{"app":"Brave Browser","interactive":true}}"#)
    b.snapshotsUntilChange = b.snapshotCount
    // The action snapshots under interactive:true and stores there.
    let act = call(d, #"{"id":3,"method":"act","params":{"app":"Brave Browser","id":2,"action":"press","interactive":true}}"#)
    try expect(act.contains("Result"), act)
    let b2 = call(d, #"{"id":4,"method":"tree","params":{"app":"Brave Browser","interactive":true}}"#)
    try expect(b2.contains(#""diff":"(no changes)""#), "interactive:true already saw the change via the action: \(b2)")
    let a2 = call(d, #"{"id":5,"method":"tree","params":{"app":"Brave Browser"}}"#)
    try expect(a2.contains("Result"), "the default filter has not: \(a2)")
  }
}
