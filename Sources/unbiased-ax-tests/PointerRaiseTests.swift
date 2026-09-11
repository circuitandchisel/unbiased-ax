import AXModel
import Foundation

// Pointer input is posted at real screen coordinates, so the window has to be
// where those coordinates are. Every other verb here works on a window the
// user cannot see. This used to be a refusal handed back to the caller, which
// cost a detour every time — measured 2026-09-10, 45 seconds of zooming,
// screenshotting and a dead canvas click before the caller asked again.
//
// Measured 2026-09-11 against the comparison agent: it brings the app forward
// for the same reason, and keeps the user's pointer by delivering events to
// the window itself. That route is not open to us — mouse events delivered to
// a process are ignored by Chromium AND by AppKit apps on this macOS, tested
// both with and without the app active — so the pointer is borrowed and given
// back instead.
func runPointerRaiseTests() {
  print("Pointer brings the app forward, then puts the pointer back")
  func call(_ d: Dispatcher, _ json: String) -> String { d.handle(line: json) }

  test("a window on another Space is brought forward instead of refused") {
    let b = FakeBackend()
    b.hideWindows = true
    let d = Dispatcher(backend: b)
    _ = call(d, #"{"id":1,"method":"tree","params":{"app":"Brave Browser"}}"#)
    let out = call(d, #"{"id":2,"method":"pointer","params":{"app":"Brave Browser","id":1,"path":[{"x":0.5,"y":0.5}]}}"#)
    try expect(!out.contains("no window on this Space"), "it no longer refuses: \(out)")
    try expect(out.contains(#""raised":true"#), out)
    try expect(out.contains("Brought Brave Browser forward"), out)
    try expectEqual(b.pointerCalls.count, 1, "the click went through")
  }

  test("the caller is told the pointer was handed back") {
    let b = FakeBackend()
    let d = Dispatcher(backend: b)
    _ = call(d, #"{"id":1,"method":"tree","params":{"app":"Brave Browser"}}"#)
    let out = call(d, #"{"id":2,"method":"pointer","params":{"app":"Brave Browser","id":1,"path":[{"x":0.5,"y":0.5}]}}"#)
    try expect(out.contains(#""pointerReturned":true"#), out)
    try expect(out.contains("put back where the user had left it"), out)
  }

  test("a window already on this Space is not raised, so nothing is disturbed") {
    let b = FakeBackend()
    let d = Dispatcher(backend: b)
    _ = call(d, #"{"id":1,"method":"tree","params":{"app":"Brave Browser"}}"#)
    let out = call(d, #"{"id":2,"method":"pointer","params":{"app":"Brave Browser","id":1,"path":[{"x":0.5,"y":0.5}]}}"#)
    try expect(!out.contains(#""raised":true"#), "nothing to bring forward: \(out)")
    try expect(!out.contains("Brought"), out)
  }

  test("reads and presses still work in the background — only the pointer brings an app forward") {
    let b = FakeBackend()
    b.hideWindows = true
    let d = Dispatcher(backend: b)
    _ = call(d, #"{"id":1,"method":"tree","params":{"app":"Brave Browser"}}"#)
    _ = call(d, #"{"id":2,"method":"act","params":{"app":"Brave Browser","id":2,"action":"press"}}"#)
    try expectEqual(b.raisedForPointer, 0, "a press never raises")
    try expectEqual(b.raised.count, 0, "and nothing else did either")
  }
}
