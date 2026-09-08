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
  /// The window server has shrunk this window's surface to a thumbnail, which
  /// is what Stage Manager does to every app the user is not looking at. Reads
  /// are unaffected, and so are keys and menu items, but the window no longer
  /// hit-tests: a press on a row, a card button or a tab is accepted and does
  /// nothing. Rendered as `[parked]`, so it is visible before anything is
  /// tried rather than only after something fails.
  public var parked: Bool
  public init(id: Int, title: String, x: Int, y: Int, width: Int, height: Int, minimized: Bool, focused: Bool, onSpace: Bool = true, parked: Bool = false) {
    self.id = id; self.title = title; self.x = x; self.y = y; self.width = width; self.height = height
    self.minimized = minimized; self.focused = focused; self.onSpace = onSpace; self.parked = parked
  }
  /// `1 "YouTube - Brave" @0,0 1200x800 [focused]` — the model reads windows the
  /// same way it reads elements.
  public var line: String {
    var parts = ["\(id) \"\(title)\" @\(x),\(y) \(width)x\(height)"]
    if focused { parts.append("[focused]") }
    if minimized { parts.append("[minimized]") }
    if parked { parts.append("[parked]") }
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
  /// `modifiers` are held around the keystroke: command, shift, option,
  /// control. Needed because a design tool's tools live behind one-letter
  /// shortcuts with no element and often no menu equivalent.
  func pressKey(app: String, key: String, modifiers: [String], focusId: Int?) throws
  /// A whole string, as real keystrokes. One step instead of one per
  /// character: "-19.6875" is nine `key` calls, and a design app's inspector
  /// wants four such numbers per shape, which does not fit a batch.
  ///
  /// Delivered as unicode key events rather than mapped virtual keys, so a
  /// minus sign, a decimal point and a hex digit all work without a keycode
  /// table. It is TEXT ENTRY, not shortcuts: `key` with modifiers remains the
  /// way to send command+a.
  func typeText(app: String, text: String, focusId: Int?) throws
  /// Pointer input inside one element: a tap at each point, or one press-drag-
  /// release through all of them when `hold` is set. Points are FRACTIONS of
  /// the element's box, so no caller ever handles screen pixels or display
  /// scaling. Returns the screen points used, so a caller can see where its
  /// fractions landed.
  ///
  /// This is the one verb that needs the window really on screen. It is
  /// hit-testing, exactly like a press, so a parked or off-Space window cannot
  /// receive it — and a click aimed where the window is not would land on
  /// whatever IS there, which is why it refuses instead of guessing.
  /// `clicks` is the click COUNT of each tap — 2 is a double click, which is a
  /// different event from two clicks in a row and is sometimes the only thing
  /// an app honours (measured: Figma's position steppers).
  func pointer(app: String, id: Int, path: [(x: Double, y: Double)], hold: Bool, modifiers: [String], clicks: Int) throws -> [CGPoint]
  func setValue(app: String, id: Int, value: String, keepFront: Bool) throws
  /// The element's value as it stands now, for reading a `setValue` back. One
  /// attribute read, no tree walk — cheap enough to check every write, which
  /// is the point: measured in Figma, a field whose old text was not cleared
  /// turned a `180` into `120180`, and seventeen later actions were computed
  /// on top of the wrong number. nil when the element exposes no value.
  func value(app: String, id: Int) throws -> String?
  func raise(app: String, windowId: Int?) throws
  /// A picture of one window, PNG, wherever the window is — another Space
  /// included — without raising anything. Measured 2026-09-05: Maps' window
  /// on another Space came back in 72ms as a real image of its UI; content the
  /// app only draws while visible (the map tiles) was black. `windowId` nil
  /// means the focused window, else the first. Needs Screen Recording.
  func screenshot(app: String, windowId: Int?) throws -> WindowShot
  /// Why an action may have done nothing, when the backend can tell (a
  /// Catalyst app backgrounded behind a fullscreen Space), else nil.
  func unresponsiveHint(app: String) -> String?
}

extension WindowInfo {
  /// Which window a caller means by "the app's window", when they did not say.
  ///
  /// Measured on Figma: it owns a 1470x33 strip beside its real 1470x923
  /// document window. The old rule — focused, else the first on this Space —
  /// picked the STRIP whenever Figma was not frontmost, and a 33-pixel band of
  /// chrome is one flat colour, so every picture came back blank. A whole
  /// 33-minute task was spent with the model concluding it had no visual
  /// channel at all; it had one, aimed at the wrong window.
  ///
  /// Focused still wins when something is focused, since that is the window a
  /// caller is working in. Otherwise take the largest by area: a document
  /// window dwarfs the toolbars, panels and strips an Electron app keeps
  /// beside it, and area needs no per-app knowledge.
  public static func likeliestDocument(_ wins: [WindowInfo]) -> WindowInfo {
    if let focused = wins.first(where: \.focused) { return focused }
    func area(_ w: WindowInfo) -> Int { max(0, w.width) * max(0, w.height) }
    // On-Space windows first, so a picture of something visible beats a bigger
    // window on another Space; within each group, the biggest.
    let onSpace = wins.filter(\.onSpace).sorted { area($0) > area($1) }
    if let best = onSpace.first { return best }
    return wins.sorted { area($0) > area($1) }.first ?? wins[0]
  }
}

public struct WindowShot {
  public var image: Data
  /// "image/jpeg" or "image/png": what `image` is encoded as.
  public var mime: String
  public var width: Int
  public var height: Int
  public var windowId: Int
  public var onSpace: Bool
  /// The picture is one colour: nothing was ever drawn in this window, or the
  /// capturing process lacks Screen Recording. Not worth handing to a model.
  public var blank: Bool
  public init(image: Data, mime: String, width: Int, height: Int, windowId: Int, onSpace: Bool, blank: Bool = false) {
    self.image = image; self.mime = mime; self.width = width; self.height = height; self.windowId = windowId; self.onSpace = onSpace; self.blank = blank
  }
}
