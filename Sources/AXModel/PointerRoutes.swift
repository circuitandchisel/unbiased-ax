import Foundation

/// Which way a click is delivered. Both are read from the environment so a
/// route can be turned off on a running machine without a rebuild — which is
/// how the question of whether the quiet route was stalling Figma runs got
/// settled, by running the same task twice with one variable changed.
public enum QuietPointer {
  /// On unless switched off. Delivers a click at a point without the cursor
  /// going there, by a route that carries no modifier or click state.
  public static func enabled(_ env: [String: String]) -> Bool {
    Switch.on(env["UNBIASED_AX_QUIET_POINTER"], default: true)
  }
}

/// Addresses the window rather than the screen: the app is never raised, the
/// window stays on its own Space, and the pointer never moves. Off by default
/// until it has drawn a full pen path and a shape-drawing run — the two
/// workloads that broke both earlier routes.
public enum BackgroundPointerRoute {
  public static func enabled(_ env: [String: String]) -> Bool {
    Switch.on(env["UNBIASED_AX_BACKGROUND_POINTER"], default: false)
  }
}

enum Switch {
  static func on(_ raw: String?, default fallback: Bool) -> Bool {
    guard let raw = raw?.trimmingCharacters(in: .whitespaces).lowercased(), !raw.isEmpty else { return fallback }
    if ["0", "false", "no", "off"].contains(raw) { return false }
    if ["1", "true", "yes", "on"].contains(raw) { return true }
    return fallback
  }
}
