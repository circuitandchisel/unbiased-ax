import AXModel
import Foundation

// Pointer input posted at real screen coordinates needs the window to be where
// those coordinates are. Every other verb here works on a window the user
// cannot see. That refusal used to be handed back to the caller, which cost a
// detour every time — measured 2026-09-10, 45 seconds of zooming,
// screenshotting and a dead canvas click before the caller asked again — so
// the app is brought forward and the pointer given back instead.
//
// An earlier version of this comment said a route that delivers to the window
// itself "is not open to us", on the strength of a measurement that posted a
// bare event with no target pid, no window number and no window-local point.
// That was wrong. Stamped properly, and aimed with a point taken from the
// accessibility frame rather than from a screenshot, the same events reach a
// window on another Space with nothing raised and the pointer untouched —
// measured 2026-09-14, clicks and drags both. See BackgroundPointer.
//
// So there are three routes now, best first: address the window, borrow the
// pointer quietly, or bring the app forward. These tests cover which one the
// caller is told about, not how any of them post.
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

  test("a window on another Space is addressed where it is, not brought forward") {
    let b = FakeBackend()
    b.hideWindows = true
    b.backgroundRoute = true
    let d = Dispatcher(backend: b)
    _ = call(d, #"{"id":1,"method":"tree","params":{"app":"Brave Browser"}}"#)
    let out = call(d, #"{"id":2,"method":"pointer","params":{"app":"Brave Browser","id":1,"path":[{"x":0.5,"y":0.5}]}}"#)
    try expectEqual(b.raisedForPointer, 0, "nothing was raised: \(out)")
    try expect(!out.contains(#""raised":true"#), out)
    try expect(!out.contains("Brought"), out)
    try expectEqual(b.pointerCalls.count, 1, "and the click still went through")
  }

  // The window route is chosen per call, so the guards it lets us skip may only
  // be skipped per call. Each of these three is a click the window route cannot
  // carry: it falls through to the event route, which posts at real screen
  // coordinates — so an off-Space window has to be brought forward first, or
  // the click lands on whatever application is actually at those coordinates.
  test("a modifier click on an off-Space window is still brought forward") {
    let b = FakeBackend()
    b.hideWindows = true
    b.backgroundRoute = true
    let d = Dispatcher(backend: b)
    _ = call(d, #"{"id":1,"method":"tree","params":{"app":"Brave Browser"}}"#)
    let out = call(d, #"{"id":2,"method":"pointer","params":{"app":"Brave Browser","id":1,"path":[{"x":0.5,"y":0.5}],"modifiers":["shift"]}}"#)
    try expectEqual(b.raisedForPointer, 1, "modifiers cannot ride the window route, so this must raise: \(out)")
  }

  test("a third click on an off-Space window is still brought forward") {
    let b = FakeBackend()
    b.hideWindows = true
    b.backgroundRoute = true
    let d = Dispatcher(backend: b)
    _ = call(d, #"{"id":1,"method":"tree","params":{"app":"Brave Browser"}}"#)
    let out = call(d, #"{"id":2,"method":"pointer","params":{"app":"Brave Browser","id":1,"path":[{"x":0.5,"y":0.5}],"clicks":3}}"#)
    try expectEqual(b.raisedForPointer, 1, "a triple click cannot ride the window route: \(out)")
  }

  test("an element whose window cannot be resolved is still brought forward") {
    // The failure a process-wide capability check cannot see: the symbols
    // resolve, the switch is on, and THIS element still has no window id.
    let b = FakeBackend()
    b.hideWindows = true
    b.backgroundRoute = true
    b.windowTargetResolves = false
    let d = Dispatcher(backend: b)
    _ = call(d, #"{"id":1,"method":"tree","params":{"app":"Brave Browser"}}"#)
    let out = call(d, #"{"id":2,"method":"pointer","params":{"app":"Brave Browser","id":1,"path":[{"x":0.5,"y":0.5}]}}"#)
    try expectEqual(b.raisedForPointer, 1, "no window id means the event route, which needs the window here: \(out)")
  }

  test("addressing the window says so, and does not claim the pointer was handed back") {
    let b = FakeBackend()
    b.backgroundRoute = true
    let d = Dispatcher(backend: b)
    _ = call(d, #"{"id":1,"method":"tree","params":{"app":"Brave Browser"}}"#)
    let out = call(d, #"{"id":2,"method":"pointer","params":{"app":"Brave Browser","id":1,"path":[{"x":0.5,"y":0.5}]}}"#)
    try expect(out.contains(#""backgrounded":true"#), out)
    try expect(out.contains(#""pointerUntouched":true"#), out)
    try expect(out.contains("was not brought forward"), out)
    try expect(!out.contains(#""pointerReturned":true"#), "nothing was borrowed to give back: \(out)")
  }

  test("a drag is addressed the same way — the cursor is not borrowed for it either") {
    let b = FakeBackend()
    b.hideWindows = true
    b.backgroundRoute = true
    let d = Dispatcher(backend: b)
    _ = call(d, #"{"id":1,"method":"tree","params":{"app":"Brave Browser"}}"#)
    let out = call(d, #"{"id":2,"method":"pointer","params":{"app":"Brave Browser","id":1,"hold":true,"path":[{"x":0.2,"y":0.2},{"x":0.8,"y":0.8}]}}"#)
    try expect(out.contains(#""backgrounded":true"#), out)
    try expectEqual(b.raisedForPointer, 0, "a drag raises nothing either: \(out)")
    try expectEqual(b.pointerCalls.first?.hold, true, "and it was a held path")
  }

  test("a double click is addressed at the window too — click state is a field, not a reason to fall back") {
    let b = FakeBackend()
    b.backgroundRoute = true
    let d = Dispatcher(backend: b)
    _ = call(d, #"{"id":1,"method":"tree","params":{"app":"Brave Browser"}}"#)
    let out = call(d, #"{"id":2,"method":"pointer","params":{"app":"Brave Browser","id":1,"clicks":2,"path":[{"x":0.5,"y":0.5}]}}"#)
    try expect(out.contains(#""backgrounded":true"#), out)
    try expectEqual(b.clickCounts.last, 2, "and it really was a double click: \(out)")
    try expectEqual(b.raisedForPointer, 0, "nothing was raised for it")
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
