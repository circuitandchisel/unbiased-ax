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
}
