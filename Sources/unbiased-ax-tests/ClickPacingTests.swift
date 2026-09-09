import AXModel
import CoreGraphics

func runClickPacingTests() {
  print("Click pacing: a click path never turns into double-clicks by accident")
  func p(_ x: Double, _ y: Double) -> CGPoint { CGPoint(x: x, y: y) }

  // Measured 2026-09-09: a 91-point pen trace had twelve consecutive points
  // within six screen points of each other, one pair on the same pixel, posted
  // about 200ms apart on a Mac whose double-click interval is 500ms. Each pair
  // was a double-click to the app, and a pen tool ends its path on one: the
  // silhouette came out as eleven open fragments, and the caller gave up on
  // the tool after three attempts.
  test("points far apart are clicked as they are: no waits, nothing dropped") {
    let plan = ClickPacing.plan([p(0, 0), p(50, 0), p(100, 40)])
    try expectEqual(plan.clicks.count, 3)
    try expect(plan.clicks.allSatisfy { !$0.waitFirst }, "no pauses needed")
    try expectEqual(plan.dropped, 0)
  }

  test("a point within the double-click radius of the last click waits out the interval first") {
    let plan = ClickPacing.plan([p(0, 0), p(4, 3), p(60, 60)])
    try expectEqual(plan.clicks.count, 3)
    try expect(!plan.clicks[0].waitFirst && plan.clicks[1].waitFirst && !plan.clicks[2].waitFirst, "\(plan.clicks.map(\.waitFirst))")
  }

  test("a point on the same pixel as the last click is not clicked twice, and the next point is judged against the kept one") {
    let plan = ClickPacing.plan([p(10, 10), p(10.4, 9.7), p(30, 10), p(30.2, 10.1), p(30.3, 10.2)])
    try expectEqual(plan.clicks.map { Int($0.point.x) }, [10, 30])
    try expectEqual(plan.dropped, 3)
    try expect(!plan.clicks[1].waitFirst, "30 is 20 away from 10; the dropped duplicate must not count as the last click")
  }

  test("a single point is one click with no wait") {
    let plan = ClickPacing.plan([p(5, 5)])
    try expectEqual(plan.clicks.count, 1)
    try expect(!plan.clicks[0].waitFirst)
  }

  test("a pointer whose path repeats a pixel says how many clicks it did not post, and why") {
    let b = FakeBackend()
    let d = Dispatcher(backend: b)
    _ = d.handle(line: #"{"id":1,"method":"tree","params":{"app":"Brave Browser"}}"#)
    // The fake maps fractions onto a 200x100 box: 0.5 and 0.501 are the same pixel.
    let out = d.handle(line: #"{"id":2,"method":"pointer","params":{"app":"Brave Browser","id":2,"path":[{"x":0.1,"y":0.5},{"x":0.5,"y":0.5},{"x":0.501,"y":0.5},{"x":0.9,"y":0.5}]}}"#)
    try expect(out.contains(#""ok":true"#), out)
    try expect(out.contains("1 point") && out.contains("same pixel") && out.contains("double-click"), out)
    try expectEqual(out.components(separatedBy: #"{"x":"#).count - 1, 3, "three clicks landed, not four: \(out)")
  }

  test("the radius is generous enough to cover what was measured breaking, and no wider") {
    // Pairs at 4.0, 4.5, 5.0 and 2.0 points broke the path; pairs at 10.6 and
    // above, in the earlier 78-point pass, did not.
    try expect(ClickPacing.doubleClickRadius >= 6 && ClickPacing.doubleClickRadius <= 10, "\(ClickPacing.doubleClickRadius)")
  }
}
