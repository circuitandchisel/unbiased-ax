import Foundation
/// The wire types. Codable so the live adapter and the tests share one shape.
public struct AppInfo: Codable, Equatable {
  public var pid: Int32, name: String, bundleId: String?, frontmost: Bool
  public init(pid: Int32, name: String, bundleId: String?, frontmost: Bool) {
    self.pid = pid; self.name = name; self.bundleId = bundleId; self.frontmost = frontmost
  }
}

public struct WindowInfo: Codable, Equatable {
  public var id: Int, title: String, x: Int, y: Int, width: Int, height: Int, minimized: Bool, focused: Bool
  /// False for a window on another Space. Such a window IS in the tree and
  /// takes actions like any other; the flag only tells the model where it is.
  public var onSpace: Bool
  public init(id: Int, title: String, x: Int, y: Int, width: Int, height: Int, minimized: Bool, focused: Bool, onSpace: Bool = true) {
    self.id = id; self.title = title; self.x = x; self.y = y; self.width = width; self.height = height
    self.minimized = minimized; self.focused = focused; self.onSpace = onSpace
  }
  /// `1 "YouTube - Brave" @0,0 1200x800 [focused]` — the model reads windows the
  /// same way it reads elements.
  public var line: String {
    var parts = ["\(id) \"\(title)\" @\(x),\(y) \(width)x\(height)"]
    if focused { parts.append("[focused]") }
    if minimized { parts.append("[minimized]") }
    if !onSpace { parts.append("[other Space]") }
    return parts.joined(separator: " ")
  }
}

public enum BridgeError: Error {
  case badParams(String)
  case unknownMethod(String)
  case notTrusted
  case noSuchApp(String)
  case noSuchElement(Int)
  case noSuchWindow(Int)
  case actionFailed(String)
  case timeout(String)
  case launchFailed(String)

  public var code: String {
    switch self {
    case .badParams: return "bad_params"
    case .unknownMethod: return "unknown_method"
    case .notTrusted: return "not_trusted"
    case .noSuchApp: return "no_such_app"
    case .noSuchElement: return "no_such_element"
    case .noSuchWindow: return "no_such_window"
    case .actionFailed: return "action_failed"
    case .timeout: return "timeout"
    case .launchFailed: return "launch_failed"
    }
  }

  public var message: String {
    switch self {
    case .badParams(let m): return m
    case .unknownMethod(let m): return "Unknown method \"\(m)\". Methods: \(Dispatcher.methods.joined(separator: ", "))."
    case .notTrusted:
      return "This process has not been granted Accessibility access. System Settings > Privacy & Security > Accessibility: enable it, then restart."
    case .noSuchApp(let a): return "No running app matches \"\(a)\". Call apps to list them."
    case .noSuchElement(let id): return "No element \(id) in the last snapshot of this app. Call tree again."
    case .noSuchWindow(let id): return "No window \(id). Call windows."
    case .actionFailed(let m): return m
    case .timeout(let m): return "The app did not respond: \(m)"
    case .launchFailed(let m): return m
    }
  }
}

/// What the live adapter provides. Everything the dispatcher needs, nothing more.
public protocol Backend: AnyObject {
  func isTrusted() -> Bool
  /// Whether windows on another Space are in the tree. True only when the live
  /// adapter has proved the private remote-token path works on this machine;
  /// false means today's behaviour, raise hints included.
  func crossSpace() -> Bool
  func apps() -> [AppInfo]
  func windows(app: String) throws -> [WindowInfo]
  /// Real windows on another Space. With crossSpace() true they ARE in the
  /// tree and this is a count for the caller's information; with it false
  /// they are the windows the window server knows that AXWindows will not
  /// list, and the only signal that "no windows" really means "elsewhere".
  func offscreenWindows(app: String) throws -> Int
  /// The app's icon as PNG bytes. A transcript that says "press #643 in Brave"
  /// reads far better beside Brave's own icon than beside a terminal glyph.
  func appIcon(app: String) throws -> Data
  func snapshot(app: String, options: SnapshotOptions) throws -> Snapshot
  /// Launch an app by name or bundle id and wait until the Accessibility API
  /// can actually see it. Without this the model has no sanctioned way to open
  /// an app that is not running, and reaches for a shell — measured: one
  /// `open -a Maps` was enough to lose it to twenty shell calls, ending in a
  /// hand-written Swift AX dumper that reimplemented this bridge.
  func launch(app: String, timeout: Double) throws -> Bool
  /// Scroll the element's container. AX exposes no scroll verb, so this posts
  /// real scroll-wheel events at the element's midpoint, to the app's pid.
  func scroll(app: String, id: Int, dx: Int, dy: Int) throws
  /// `keepFront` restores whatever application was in front before the action.
  /// OFF by default, and that default is the important part: measured on a
  /// native app, setValue does not pull its app forward at all. Restoring
  /// after every action only un-does the one raise that made the app readable,
  /// so the next read finds it gone and raises again — a switch per action.
  /// Raise once, work there, and leave the user where the work is.
  func perform(app: String, id: Int, action: String, keepFront: Bool) throws
  /// A named key, delivered to the app as a real key event. For what the
  /// Accessibility API has no verb for: committing an omnibox, dismissing a
  /// sheet, moving through a list.
  /// `focusId` focuses that element first, so the key lands where the caller
  /// means it to. Without it the key goes wherever keyboard focus already is,
  /// which is how "space to play a video" typed spaces into an address bar.
  func pressKey(app: String, key: String, focusId: Int?) throws
  func setValue(app: String, id: Int, value: String, keepFront: Bool) throws
  func raise(app: String, windowId: Int?) throws
  /// A picture of one window, PNG, wherever the window is — another Space
  /// included — without raising anything. Measured 2026-09-05: Maps' window
  /// on another Space came back in 72ms as a real image of its UI; content the
  /// app only draws while visible (the map tiles) was black. `windowId` nil
  /// means the focused window, else the first. Needs Screen Recording.
  func screenshot(app: String, windowId: Int?) throws -> WindowShot
}

public struct WindowShot {
  public var png: Data
  public var width: Int
  public var height: Int
  public var windowId: Int
  public var onSpace: Bool
  public init(png: Data, width: Int, height: Int, windowId: Int, onSpace: Bool) {
    self.png = png; self.width = width; self.height = height; self.windowId = windowId; self.onSpace = onSpace
  }
}
