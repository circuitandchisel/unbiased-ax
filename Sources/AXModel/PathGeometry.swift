import Foundation

/// Geometry of a click path, checked before anything is posted.
///
/// A path of clicks that traces an outline is the shape the app will fill,
/// and an outline that crosses itself is never the shape anyone meant: the app
/// fills it inside out where it folds. Measured 2026-09-10 — an 81-point trace
/// went out to a ray's tip, came back to a point that lay INSIDE the body, and
/// went out again; two segments crossed two others, the fill showed a twisted
/// spike, and the run spent two and a half minutes on tools it did not have
/// trying to redraw it. The crossing was in the coordinates before the first
/// click, where it costs nothing to find.
public enum PathGeometry {
  /// A pair of non-adjacent segments that cross, as 0-based indices of the
  /// segment's first point, or nil when the path does not cross itself.
  /// The closing segment (last point back to the first) counts only when the
  /// path is closed, i.e. its last point is on its first.
  public static func selfCrossing(_ pts: [(x: Double, y: Double)]) -> (a: Int, b: Int)? {
    let n = pts.count
    guard n >= 4 else { return nil }
    let closed = abs(pts[0].x - pts[n - 1].x) < 0.002 && abs(pts[0].y - pts[n - 1].y) < 0.002
    // Segment i runs from point i to point i+1; a closed path's last segment
    // already ends on the first point, so it and segment 0 are neighbours and
    // are not tested against each other.
    let segments = n - 1
    for i in 0..<segments {
      for j in stride(from: i + 2, to: segments, by: 1) where !(closed && i == 0 && j == segments - 1) {
        if cross(pts[i], pts[i + 1], pts[j], pts[j + 1]) { return (i, j) }
      }
    }
    return nil
  }

  /// Proper crossing only: touching at an endpoint or running along the same
  /// line is not a fold, and a pair of points on one pixel makes a zero-length
  /// segment that must not count.
  private static func cross(_ a: (x: Double, y: Double), _ b: (x: Double, y: Double),
                            _ c: (x: Double, y: Double), _ d: (x: Double, y: Double)) -> Bool {
    func orient(_ p: (x: Double, y: Double), _ q: (x: Double, y: Double), _ r: (x: Double, y: Double)) -> Double {
      (q.x - p.x) * (r.y - p.y) - (q.y - p.y) * (r.x - p.x)
    }
    let d1 = orient(c, d, a), d2 = orient(c, d, b), d3 = orient(a, b, c), d4 = orient(a, b, d)
    return d1 * d2 < 0 && d3 * d4 < 0
  }
}
