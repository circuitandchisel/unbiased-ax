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
/// window stays on its own Space, and the pointer never moves.
///
/// ON by default since 2026-09-18, when it finally drew the run it was waiting
/// for — a full pen path traced into a Figma frame, every pointer call
/// recorded as the window route, the app never raised and the cursor never
/// taken. The same drawing with this off had raised Figma and driven the real
/// pointer for ten minutes, and cost 624 seconds and 89 turns against 169 and
/// 22.
///
/// The default was the wrong way round for a second reason, which only showed
/// once someone watched a run: the agent cursor is drawn ONLY on this route,
/// because it is the only one where there is no real pointer to follow. So off
/// meant the agent took the user's cursor AND drew nothing to explain why —
/// intrusive and invisible at once.
///
/// Turning it on cannot break a machine that cannot do it: the route is gated
/// again at the call site by BackgroundPointer.available, which needs several
/// private symbols to resolve. Where they do not, this falls back to the
/// earlier routes exactly as before.
public enum BackgroundPointerRoute {
  public static func enabled(_ env: [String: String]) -> Bool {
    Switch.on(env["UNBIASED_AX_BACKGROUND_POINTER"], default: true)
  }
}

/// The drawn pointer that shows where the agent is working. On by default: a
/// click that moves nothing is invisible, and a window changing for no visible
/// reason is worse than a mark on screen. Only ever drawn for the window route,
/// where there is no real cursor to watch.
public enum AgentCursorSwitch {
  public static func enabled(_ env: [String: String]) -> Bool {
    Switch.on(env["UNBIASED_AX_AGENT_CURSOR"], default: true)
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
