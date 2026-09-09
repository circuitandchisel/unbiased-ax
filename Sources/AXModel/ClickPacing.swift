import CoreGraphics

/// How a many-point click path is paced so the app under it never sees a
/// double-click the caller did not ask for.
///
/// Measured 2026-09-09: a 91-point pen trace had twelve consecutive points
/// within six screen points of each other, one pair on the very same pixel,
/// posted about 200ms apart on a Mac whose double-click interval is 500ms.
/// Two clicks that close in space and time ARE a double-click, whoever
/// counts them, and a pen tool ends its path on one. The silhouette came out
/// as eleven open fragments; the caller tried twice more, then abandoned the
/// tool for a route the task had forbidden. A single click is what was
/// asked for, so a single click is what has to arrive.
public enum ClickPacing {
  /// Closer than this to the previous click and the next one waits out the
  /// double-click interval before it is posted. Pairs at 2 to 5 points broke
  /// the path; pairs at 10.6 and above did not.
  public static let doubleClickRadius: CGFloat = 8
  /// Closer than this and it is the same pixel: a second click there is not a
  /// second vertex, it is a double-click at best and a removed anchor at worst.
  public static let samePixel: CGFloat = 1

  public struct Step: Equatable {
    public var point: CGPoint
    public var waitFirst: Bool
  }
  public struct Plan: Equatable {
    public var clicks: [Step]
    public var dropped: Int
  }

  public static func plan(_ points: [CGPoint], radius: CGFloat = doubleClickRadius) -> Plan {
    var clicks: [Step] = []
    var dropped = 0
    var last: CGPoint? = nil
    for pt in points {
      if let l = last {
        let d = hypot(pt.x - l.x, pt.y - l.y)
        if d < samePixel { dropped += 1; continue }
        clicks.append(Step(point: pt, waitFirst: d <= radius))
      } else {
        clicks.append(Step(point: pt, waitFirst: false))
      }
      last = pt
    }
    return Plan(clicks: clicks, dropped: dropped)
  }
}
