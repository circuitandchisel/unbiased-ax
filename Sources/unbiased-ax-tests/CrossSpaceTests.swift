import Foundation
import AXModel

/// AXWindows lists only the current Space. With the private remote-token path
/// the bridge reaches windows anywhere, and the model must never be told to
/// raise again. These pin what the model sees in both worlds.
func runCrossSpaceTests() {
  print("Across Spaces")
  func call(_ d: Dispatcher, _ json: String) -> String { d.handle(line: json) }

  test("hello says whether the bridge reads across Spaces") {
    let b = FakeBackend()
    try expect(call(Dispatcher(backend: b), #"{"id":1,"method":"hello"}"#).contains(#""crossSpace":false"#))
    b.crossSpaceOn = true
    try expect(call(Dispatcher(backend: b), #"{"id":2,"method":"hello"}"#).contains(#""crossSpace":true"#))
  }

  test("an off-Space window is listed and marked, not hidden") {
    let b = FakeBackend(); b.crossSpaceOn = true; b.hideWindows = true
    let out = call(Dispatcher(backend: b), #"{"id":3,"method":"windows","params":{"app":"Brave Browser"}}"#)
    try expect(out.contains("YouTube - Brave"), "the window is there to be read: \(out)")
    try expect(out.contains("[other Space]"), "and the model can see it is elsewhere: \(out)")
    try expect(out.contains(#""onSpace":false"#), out)
  }

  test("a window on this Space carries no Space marker") {
    let b = FakeBackend(); b.crossSpaceOn = true   // the flag alone must not mark anything
    let out = call(Dispatcher(backend: b), #"{"id":6,"method":"windows","params":{"app":"Brave Browser"}}"#)
    try expect(out.contains(#""onSpace":true"#), out)
    try expect(!out.contains("[other Space]"), out)
    try expect(!out.contains("hint"), out)
  }

  test("a read across Spaces carries no raise hint, and still counts what is elsewhere") {
    // The whole point: the model must never be sent to raise for a window it
    // can already read. The count stays so a UI can say where the work is.
    let b = FakeBackend(); b.crossSpaceOn = true; b.hideWindows = true; b.offscreen = 1
    for method in ["tree", "windows", "find", "launch"] {
      let out = call(Dispatcher(backend: b), #"{"id":4,"method":"\#(method)","params":{"app":"Brave Browser","title":"OK"}}"#)
      try expect(out.contains(#""offscreen":1"#), "\(method) must still report the count: \(out)")
      try expect(!out.contains("hint"), "\(method) must not hint when the window is readable: \(out)")
      try expect(!out.contains("call raise") && !out.contains("do not raise"), "\(method) must never instruct a raise: \(out)")
    }
  }

  test("with cross-Space off, the hint is exactly what it was") {
    let b = FakeBackend(); b.hideWindows = true; b.offscreen = 1
    let out = call(Dispatcher(backend: b), #"{"id":5,"method":"tree","params":{"app":"Brave Browser"}}"#)
    try expect(out.contains("call raise for this app first"), out)
  }

  test("across Spaces, a window the scan could not reach yet is reported as that — read again, never raise") {
    // A fresh launch before its window is vended, or a first scan that aborted:
    // the window server lists a window and the tree has none. Saying "no
    // windows" here is the eight-bare-elements failure all over again.
    let b = FakeBackend(); b.crossSpaceOn = true; b.unreachable = true; b.offscreen = 1
    let out = call(Dispatcher(backend: b), #"{"id":7,"method":"tree","params":{"app":"Brave Browser"}}"#)
    try expect(out.contains(#""offscreen":1"#), out)
    try expect(out.contains("could not be read yet"), "must say the window exists and is not reachable yet: \(out)")
    try expect(out.contains("Read again"), out)
    try expect(!out.contains("call raise"), "must never send the model to raise across Spaces: \(out)")
  }
}
