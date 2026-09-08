import AXModel
import Foundation

func runEscapeSettleTests() {
  print("Settle: escape closes things")
  func call(_ d: Dispatcher, _ json: String) -> String { d.handle(line: json) }

  // Measured 2026-09-08: eight escapes after Figma's colour picker, each paying
  // the 3.5s shrunk-tree deadline. The picker is not coming back — a smaller
  // tree is escape's honest final state, not a transition.
  test("escape closing something is a settled shrink, not a transition: no long deadline") {
    let b = FakeBackend()
    b.shrunkUntilSnapshot = 1_000 // the tree stays shrunk: the picker is closed for good
    b.shrinkBy = 30
    let d = Dispatcher(backend: b)
    _ = call(d, #"{"id":1,"method":"tree","params":{"app":"Brave Browser"}}"#)
    let started = Date()
    let out = call(d, #"{"id":2,"method":"key","params":{"app":"Brave Browser","key":"escape"}}"#)
    let elapsed = Date().timeIntervalSince(started)
    try expect(out.contains("removed"), out)
    try expect(elapsed < 2.0, "escape must settle on the ordinary deadline, took \(elapsed)s")
  }

  test("any other key still treats a large shrink as a transition") {
    let b = FakeBackend()
    b.shrunkUntilSnapshot = 1_000
    b.shrinkBy = 30
    let d = Dispatcher(backend: b)
    _ = call(d, #"{"id":1,"method":"tree","params":{"app":"Brave Browser"}}"#)
    let started = Date()
    _ = call(d, #"{"id":2,"method":"key","params":{"app":"Brave Browser","key":"return"}}"#)
    let elapsed = Date().timeIntervalSince(started)
    try expect(elapsed >= 3.3, "return after a collapse waits for what replaces it, took \(elapsed)s")
  }
}
