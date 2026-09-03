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
  public init(id: Int, title: String, x: Int, y: Int, width: Int, height: Int, minimized: Bool, focused: Bool) {
    self.id = id; self.title = title; self.x = x; self.y = y; self.width = width; self.height = height
    self.minimized = minimized; self.focused = focused
  }
  /// `1 "YouTube - Brave" @0,0 1200x800 [focused]` — the model reads windows the
  /// same way it reads elements.
  public var line: String {
    var parts = ["\(id) \"\(title)\" @\(x),\(y) \(width)x\(height)"]
    if focused { parts.append("[focused]") }
    if minimized { parts.append("[minimized]") }
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
    }
  }
}

/// What the live adapter provides. Everything the dispatcher needs, nothing more.
public protocol Backend: AnyObject {
  func isTrusted() -> Bool
  func apps() -> [AppInfo]
  func windows(app: String) throws -> [WindowInfo]
  /// Windows the window server knows about that the Accessibility API does
  /// not list — on another Space, or hidden. AXWindows only sees the current
  /// Space, so without this a model cannot tell "no windows" from "elsewhere".
  func offscreenWindows(app: String) throws -> Int
  /// The app's icon as PNG bytes. A transcript that says "press #643 in Brave"
  /// reads far better beside Brave's own icon than beside a terminal glyph.
  func appIcon(app: String) throws -> Data
  func snapshot(app: String, options: SnapshotOptions) throws -> Snapshot
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
}
