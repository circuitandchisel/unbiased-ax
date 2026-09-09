import AXModel

func runHitTests() {
  print("Aim and focus are checked against the app before anything is posted")
  func call(_ d: Dispatcher, _ json: String) -> String { d.handle(line: json) }

  // Measured 2026-09-08: an element's reported bounds can lag what the app is
  // drawing — a canvas node said it was at a point where the app had put a
  // different node. Clicking there selected the wrong object, and the caller
  // needed a dozen turns to find out. The app itself can say what is at a
  // point; ask it before posting.
  test("a pointer whose first point lands on an unrelated element is refused, and nothing is clicked") {
    let b = FakeBackend()
    b.pointerHitResult = .unrelated(role: "group", title: "Other frame")
    let d = Dispatcher(backend: b)
    _ = call(d, #"{"id":1,"method":"tree","params":{"app":"Brave Browser"}}"#)
    let out = call(d, #"{"id":2,"method":"pointer","params":{"app":"Brave Browser","id":2,"path":[{"x":0.5,"y":0.5}]}}"#)
    try expect(out.contains("action_failed"), out)
    try expect(out.contains(#"group \"Other frame\""#) && out.contains("not inside element 2"), "names what IS there: \(out)")
    try expect(out.contains("Nothing was clicked") && out.contains("Read the app again"), out)
    try expectEqual(b.pointerCalls.count, 0)
  }

  test("a pointer whose first point has nothing under it is refused") {
    let b = FakeBackend()
    b.pointerHitResult = .nothing
    let d = Dispatcher(backend: b)
    _ = call(d, #"{"id":1,"method":"tree","params":{"app":"Brave Browser"}}"#)
    let out = call(d, #"{"id":2,"method":"pointer","params":{"app":"Brave Browser","id":2}}"#)
    try expect(out.contains("action_failed") && out.contains("nothing at the first point"), out)
    try expectEqual(b.pointerCalls.count, 0)
  }

  // Measured 2026-09-09: three of these in ninety seconds while the caller
  // tried to click a layer row, on a surface that reports nothing anywhere.
  // Repeating the same sentence taught it nothing; it tried two more clicks.
  test("a second refusal on the same app says aiming by point does not work here, and what does") {
    let b = FakeBackend()
    b.pointerHitResult = .nothing
    let d = Dispatcher(backend: b)
    _ = call(d, #"{"id":1,"method":"tree","params":{"app":"Brave Browser"}}"#)
    let first = call(d, #"{"id":2,"method":"pointer","params":{"app":"Brave Browser","id":2}}"#)
    try expect(!first.contains("2nd time"), "the first refusal stays short: \(first)")
    let second = call(d, #"{"id":3,"method":"pointer","params":{"app":"Brave Browser","id":2}}"#)
    try expect(second.contains("2nd time") && second.contains("does not report what is under a point"), second)
    try expect(second.contains("find") && second.contains("keyboard"), "names the routes that do work: \(second)")
    let third = call(d, #"{"id":4,"method":"pointer","params":{"app":"Brave Browser","id":2}}"#)
    try expect(third.contains("3rd time"), third)
    try expectEqual(b.pointerCalls.count, 0)
  }

  test("a pointer that lands resets the count, so a one-off miss never escalates") {
    let b = FakeBackend()
    b.pointerHitResult = .nothing
    let d = Dispatcher(backend: b)
    _ = call(d, #"{"id":1,"method":"tree","params":{"app":"Brave Browser"}}"#)
    _ = call(d, #"{"id":2,"method":"pointer","params":{"app":"Brave Browser","id":2}}"#)
    b.pointerHitResult = .inside
    _ = call(d, #"{"id":3,"method":"pointer","params":{"app":"Brave Browser","id":2}}"#)
    b.pointerHitResult = .nothing
    let again = call(d, #"{"id":4,"method":"pointer","params":{"app":"Brave Browser","id":2}}"#)
    try expect(!again.contains("2nd time"), "the app proved it can hit-test: \(again)")
  }

  // One-sided, like every other guard here: refuse only on evidence. An
  // ancestor under the point proves nothing either way, so it passes.
  test("a pointer landing on the anchor, a descendant, or a container of it proceeds") {
    for rel in [HitRelation.inside, HitRelation.container] {
      let b = FakeBackend()
      b.pointerHitResult = rel
      let d = Dispatcher(backend: b)
      _ = call(d, #"{"id":1,"method":"tree","params":{"app":"Brave Browser"}}"#)
      let out = call(d, #"{"id":2,"method":"pointer","params":{"app":"Brave Browser","id":2}}"#)
      try expect(out.contains(#""ok":true"#), "\(rel): \(out)")
      try expectEqual(b.pointerCalls.count, 1)
    }
  }

  // Measured 2026-09-08: a coordinate typed after a click that had not focused
  // the field went to the canvas, where digits are shortcuts; two shapes came
  // out at 28% opacity and it took six turns to notice and repair.
  test("typing with no id is refused when keyboard focus is not on something editable") {
    let b = FakeBackend()
    b.focusedControlValue = (role: "web area", title: "Untitled")
    let d = Dispatcher(backend: b)
    _ = call(d, #"{"id":1,"method":"tree","params":{"app":"Brave Browser"}}"#)
    let out = call(d, #"{"id":2,"method":"type","params":{"app":"Brave Browser","text":"256"}}"#)
    try expect(out.contains("action_failed"), out)
    try expect(out.contains(#"web area \"Untitled\""#) && out.contains("shortcuts") && out.contains("Nothing was typed"), out)
    try expect(out.contains("Pass id"), "says how to aim: \(out)")
    try expectEqual(b.typed.count, 0)
  }

  test("typing with no id is refused when nothing has focus at all") {
    let b = FakeBackend()
    b.focusedControlValue = nil
    let d = Dispatcher(backend: b)
    _ = call(d, #"{"id":1,"method":"tree","params":{"app":"Brave Browser"}}"#)
    let out = call(d, #"{"id":2,"method":"type","params":{"app":"Brave Browser","text":"hello"}}"#)
    try expect(out.contains("action_failed") && out.contains("no element"), out)
    try expectEqual(b.typed.count, 0)
  }

  test("typing proceeds into an editable focus, and always when an id names the field") {
    let b = FakeBackend()
    b.focusedControlValue = (role: "incrementor", title: "X-position")
    let d = Dispatcher(backend: b)
    _ = call(d, #"{"id":1,"method":"tree","params":{"app":"Brave Browser"}}"#)
    let free = call(d, #"{"id":2,"method":"type","params":{"app":"Brave Browser","text":"256"}}"#)
    try expect(free.contains(#""ok":true"#), free)
    b.focusedControlValue = (role: "web area", title: "Untitled") // focus elsewhere, but the id focuses the field first
    let aimed = call(d, #"{"id":3,"method":"type","params":{"app":"Brave Browser","id":3,"text":"b.com"}}"#)
    try expect(aimed.contains(#""ok":true"#), aimed)
    try expectEqual(b.typed.count, 2)
  }
}
