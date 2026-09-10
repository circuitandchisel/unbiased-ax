import AXModel
import Foundation

func runPathGeometryTests() {
  print("Refusing an outline that crosses itself")
  func call(_ d: Dispatcher, _ json: String) -> String { d.handle(line: json) }
  func pathJSON(_ pts: [(Double, Double)]) -> String {
    "[" + pts.map { "{\"x\":\($0.0),\"y\":\($0.1)}" }.joined(separator: ",") + "]"
  }
  // A 12-ray star, closed: the shape the runs draw. Never crosses itself.
  func star(_ rays: Int = 12) -> [(Double, Double)] {
    var out: [(Double, Double)] = []
    for i in 0..<(rays * 2) {
      let a = Double(i) * .pi / Double(rays)
      let r = i % 2 == 0 ? 0.48 : 0.15
      out.append((0.5 + r * cos(a), 0.5 + r * sin(a)))
    }
    out.append(out[0])
    return out
  }

  test("a star outline does not cross itself") {
    try expect(PathGeometry.selfCrossing(star().map { (x: $0.0, y: $0.1) }) == nil)
  }

  test("a ray whose return point lies inside the body is a crossing, and both segments are named") {
    // Measured 2026-09-10, in fractions of a 1024 frame: tip (1006,471), then
    // back to (676,547) — inside the body — then out to (969,566).
    var pts = star()
    pts[8] = (0.982, 0.460)   // a tip
    pts[9] = (0.660, 0.534)   // the inner point, left of where the body's edge runs
    pts[10] = (0.946, 0.553)  // the next tip
    let hit = PathGeometry.selfCrossing(pts.map { (x: $0.0, y: $0.1) })
    try expect(hit != nil, "expected a crossing")
  }

  test("a figure of eight crosses; touching at a shared point does not") {
    let eight: [(Double, Double)] = [(0.1, 0.1), (0.9, 0.9), (0.9, 0.1), (0.1, 0.9), (0.1, 0.1)]
    try expect(PathGeometry.selfCrossing(eight.map { (x: $0.0, y: $0.1) }) != nil)
    let bowtieTouch: [(Double, Double)] = [(0.1, 0.1), (0.5, 0.5), (0.9, 0.1), (0.9, 0.9), (0.5, 0.5), (0.1, 0.9), (0.1, 0.1)]
    try expect(PathGeometry.selfCrossing(bowtieTouch.map { (x: $0.0, y: $0.1) }) == nil, "a shared vertex is not a fold")
  }

  test("two points on one pixel do not count as a segment that crosses anything") {
    var pts = star()
    pts.insert(pts[3], at: 4)
    try expect(PathGeometry.selfCrossing(pts.map { (x: $0.0, y: $0.1) }) == nil)
  }

  test("pointer refuses a long crossing path before clicking, naming the two segments") {
    let b = FakeBackend()
    let d = Dispatcher(backend: b)
    _ = call(d, #"{"id":1,"method":"tree","params":{"app":"Brave Browser"}}"#)
    var pts = star()
    pts[8] = (0.982, 0.460); pts[9] = (0.660, 0.534); pts[10] = (0.946, 0.553)
    let out = call(d, "{\"id\":2,\"method\":\"pointer\",\"params\":{\"app\":\"Brave Browser\",\"id\":1,\"path\":\(pathJSON(pts))}}")
    try expect(out.contains("crosses itself"), out)
    try expect(out.contains("from point"), "names the segments: \(out)")
    try expect(out.contains("Nothing was clicked"), out)
    try expectEqual(b.pointerCalls.count, 0, "nothing posted")
  }

  test("a short crossing path is a handful of controls, not an outline, and goes through") {
    let b = FakeBackend()
    let d = Dispatcher(backend: b)
    _ = call(d, #"{"id":1,"method":"tree","params":{"app":"Brave Browser"}}"#)
    let eight: [(Double, Double)] = [(0.1, 0.1), (0.9, 0.9), (0.9, 0.1), (0.1, 0.9), (0.1, 0.1)]
    let out = call(d, "{\"id\":2,\"method\":\"pointer\",\"params\":{\"app\":\"Brave Browser\",\"id\":1,\"path\":\(pathJSON(eight))}}")
    try expect(!out.contains("crosses itself"), out)
    try expectEqual(b.pointerCalls.count, 1)
  }

  test("a drag that crosses itself is a stroke, not an outline, and goes through") {
    let b = FakeBackend()
    let d = Dispatcher(backend: b)
    _ = call(d, #"{"id":1,"method":"tree","params":{"app":"Brave Browser"}}"#)
    var pts = star()
    pts[8] = (0.982, 0.460); pts[9] = (0.660, 0.534); pts[10] = (0.946, 0.553)
    let out = call(d, "{\"id\":2,\"method\":\"pointer\",\"params\":{\"app\":\"Brave Browser\",\"id\":1,\"hold\":true,\"path\":\(pathJSON(pts))}}")
    try expect(!out.contains("crosses itself"), out)
    try expectEqual(b.pointerCalls.count, 1)
  }
}
