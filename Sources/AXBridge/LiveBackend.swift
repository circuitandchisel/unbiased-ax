import CoreGraphics
import Foundation
import AppKit
import ApplicationServices
import AXModel

/// The live adapter. Thin on purpose: every decision that CAN be pure lives in
/// AXModel and is tested there. What is here is the AX API and nothing else.
public final class LiveBackend: Backend {
  private var registries: [pid_t: IdRegistry] = [:]
  /// id -> element from the last snapshot (or windows call), so act/setValue
  /// resolve an id the model saw to the element it meant.
  private var elements: [pid_t: [Int: AXElement]] = [:]

  public init() {}

  public func isTrusted() -> Bool { AXIsProcessTrusted() }

  public func apps() -> [AppInfo] {
    NSWorkspace.shared.runningApplications
      .filter { $0.activationPolicy == .regular }
      .map { AppInfo(pid: $0.processIdentifier, name: $0.localizedName ?? "?", bundleId: $0.bundleIdentifier, frontmost: $0.isActive) }
  }

  /// Name, bundle id, or pid — case-insensitive, prefix-tolerant ("Brave" finds "Brave Browser").
  func resolve(_ app: String) throws -> NSRunningApplication {
    let apps = NSWorkspace.shared.runningApplications.filter { $0.activationPolicy == .regular }
    if let pid = Int32(app), let a = apps.first(where: { $0.processIdentifier == pid }) { return a }
    let q = app.lowercased()
    if let a = apps.first(where: { $0.bundleIdentifier?.lowercased() == q || $0.localizedName?.lowercased() == q }) { return a }
    if let a = apps.first(where: { ($0.localizedName ?? "").lowercased().hasPrefix(q) }) { return a }
    throw BridgeError.noSuchApp(app)
  }

  private func appElement(_ a: NSRunningApplication) -> AXElement {
    let e = AXUIElementCreateApplication(a.processIdentifier)
    // One unresponsive app must never hang the whole bridge.
    AXUIElementSetMessagingTimeout(e, 1.0)
    return AXElement(ref: e)
  }

  public func windows(app: String) throws -> [WindowInfo] {
    let a = try resolve(app)
    let root = appElement(a)
    var v: CFTypeRef?
    let err = AXUIElementCopyAttributeValue(root.ref, kAXWindowsAttribute as CFString, &v)
    if LiveSource.debug {
      FileHandle.standardError.write("[ax] AXWindows for \(a.localizedName ?? app): AXError \(err.rawValue), \(axElements(v).count) element(s)\n".data(using: .utf8)!)
    }
    if err == .cannotComplete { throw BridgeError.timeout("\(a.localizedName ?? app) did not list its windows") }
    guard err == .success else { return [] }
    let src = LiveSource()
    var reg = registries[a.processIdentifier] ?? IdRegistry()
    var out: [WindowInfo] = []
    for w in axElements(v) {
      let el = AXElement(ref: w)
      guard let at = src.attributes(of: el) else { continue }
      var minimized: CFTypeRef?
      AXUIElementCopyAttributeValue(w, kAXMinimizedAttribute as CFString, &minimized)
      let id = reg.id(for: el)
      elements[a.processIdentifier, default: [:]][id] = el
      out.append(WindowInfo(id: id, title: at.title ?? "", x: at.x, y: at.y, width: at.width, height: at.height,
                            minimized: (minimized as? Bool) ?? false, focused: at.focused))
    }
    registries[a.processIdentifier] = reg
    return out
  }

  public func offscreenWindows(app: String) throws -> Int {
    let a = try resolve(app)
    let list = (CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID) as? [[String: Any]]) ?? []
    return list.filter {
      ($0[kCGWindowOwnerPID as String] as? Int32) == a.processIdentifier
        && (($0[kCGWindowLayer as String] as? Int) ?? 1) == 0
        && !(($0[kCGWindowIsOnscreen as String] as? Bool) ?? false)
    }.count
  }

  public func appIcon(app: String) throws -> Data {
    let a = try resolve(app)
    guard let url = a.bundleURL else { throw BridgeError.noSuchApp(app) }
    let icon = NSWorkspace.shared.icon(forFile: url.path)
    // Setting NSImage.size is only a display hint: tiffRepresentation still
    // hands back the largest representation, which measured 1.8MB for one
    // icon. Draw into a bitmap of the size we actually want instead.
    let side = 64   // 32pt at 2x, so it stays sharp on a retina display
    guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: side, pixelsHigh: side,
                                     bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                     colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else {
      throw BridgeError.actionFailed("could not allocate a bitmap for \(a.localizedName ?? app)'s icon")
    }
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    icon.draw(in: NSRect(x: 0, y: 0, width: side, height: side))
    NSGraphicsContext.restoreGraphicsState()
    guard let png = rep.representation(using: .png, properties: [:]) else {
      throw BridgeError.actionFailed("could not render \(a.localizedName ?? app)'s icon as PNG")
    }
    return png
  }

  public func snapshot(app: String, options: SnapshotOptions) throws -> Snapshot {
    let a = try resolve(app)
    let root = appElement(a)
    if options.webContent {
      // What VoiceOver sets. Without it Chromium exposes only its own chrome
      // and tabs; page content is not in the tree at all.
      AXUIElementSetAttributeValue(root.ref, "AXEnhancedUserInterface" as CFString, kCFBooleanTrue)
    }
    var probe: CFTypeRef?
    let probeErr = AXUIElementCopyAttributeValue(root.ref, kAXRoleAttribute as CFString, &probe)
    guard probeErr == .success else {
      // Silent emptiness hid this once already (Finder returned count 0 with
      // no explanation). Name the code so the next report is diagnosable.
      throw BridgeError.actionFailed("\(a.localizedName ?? app) did not answer the Accessibility API (AXError \(probeErr.rawValue)). -25204 is cannotComplete: the app is busy, or is not accessibility-enabled; -25211 is notImplemented; -25201 is invalid element.")
    }
    if LiveSource.debug, let at = LiveSource(appRoot: root).attributes(of: root) {
      FileHandle.standardError.write("[ax] root: role=\(at.role) title=\(at.title ?? "-") size=\(at.width)x\(at.height) geometryKnown=\(at.geometryKnown) children=\(LiveSource(appRoot: root).children(of: root).count)\n".data(using: .utf8)!)
    }
    var reg = registries[a.processIdentifier] ?? IdRegistry()
    let snap = Snapshot.build(root: root, source: LiveSource(appRoot: root), registry: &reg, options: options)
    registries[a.processIdentifier] = reg
    var map: [Int: AXElement] = [:]
    for n in snap.nodes { if let el = reg.identity(for: n.id)?.base as? AXElement { map[n.id] = el } }
    elements[a.processIdentifier] = map
    return snap
  }

  private func element(_ app: String, _ id: Int) throws -> (NSRunningApplication, AXElement) {
    let a = try resolve(app)
    guard let el = elements[a.processIdentifier]?[id] else { throw BridgeError.noSuchElement(id) }
    return (a, el)
  }

  /// Run `body`, then put back whatever app was in front if it changed.
  /// Measured: acting on a browser on another Space took the user there on
  /// every single action, which is the opposite of working in the background.
  private func keepingFront<T>(_ keepFront: Bool, _ body: () throws -> T) rethrows -> T {
    guard keepFront else { return try body() }
    let before = NSWorkspace.shared.frontmostApplication
    let result = try body()
    guard let before, before.processIdentifier != NSWorkspace.shared.frontmostApplication?.processIdentifier else {
      return result
    }
    // A short settle: the app we acted on may still be coming forward, and
    // reactivating into that race just loses.
    usleep(120_000)
    before.activate(options: [])
    return result
  }

  public func perform(app: String, id: Int, action: String, keepFront: Bool) throws {
    try keepingFront(keepFront) { try performInner(app: app, id: id, action: action) }
  }

  private func performInner(app: String, id: Int, action: String) throws {
    let (_, el) = try element(app, id)
    let ax: String
    switch action {
    case "press": ax = kAXPressAction
    case "raise": ax = kAXRaiseAction
    case "show menu": ax = kAXShowMenuAction
    case "confirm": ax = kAXConfirmAction   // commits a text field: Chromium's omnibox needs this, not press
    case "focus":
      let err = AXUIElementSetAttributeValue(el.ref, kAXFocusedAttribute as CFString, kCFBooleanTrue)
      guard err == .success else { throw BridgeError.actionFailed("focus failed (AXError \(err.rawValue))") }
      return
    default:
      // "show menu" style names back to AXShowMenu, for any action the tree listed.
      ax = "AX" + action.split(separator: " ").map { $0.prefix(1).uppercased() + $0.dropFirst() }.joined()
    }
    let err = AXUIElementPerformAction(el.ref, ax as CFString)
    switch err {
    case .success: return
    case .cannotComplete: throw BridgeError.timeout("action \(action) on element \(id)")
    default: throw BridgeError.actionFailed("\(action) failed (AXError \(err.rawValue)). The actions this element supports are the ones listed in braces in the tree.")
    }
  }

  static let keyCodes: [String: CGKeyCode] = [
    "return": 36, "tab": 48, "escape": 53, "space": 49, "delete": 51, "up": 126, "down": 125, "left": 123, "right": 124,
  ]

  public func pressKey(app: String, key: String, focusId: Int?) throws {
    let a = try resolve(app)
    // Focus first when the caller named a target: a key event goes to whatever
    // holds keyboard focus, and "space to play" in an omnibox types a space.
    if let id = focusId {
      let (_, el) = try element(app, id)
      AXUIElementSetAttributeValue(el.ref, kAXFocusedAttribute as CFString, kCFBooleanTrue)
    }
    guard let code = Self.keyCodes[key] else { throw BridgeError.badParams("Unknown key \"\(key)\".") }
    // Posted to the pid, not the system: it reaches the app whether or not it
    // is frontmost, and cannot land in some other window by accident.
    guard let down = CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: true),
          let up = CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: false) else {
      throw BridgeError.actionFailed("could not create key event")
    }
    down.postToPid(a.processIdentifier)
    up.postToPid(a.processIdentifier)
  }

  public func setValue(app: String, id: Int, value: String, keepFront: Bool) throws {
    try keepingFront(keepFront) { try setValueInner(app: app, id: id, value: value) }
  }

  private func setValueInner(app: String, id: Int, value: String) throws {
    let (_, el) = try element(app, id)
    // Focus first: Chromium accepts a value on an unfocused omnibox but does
    // not commit it, so the address changes and nothing happens.
    AXUIElementSetAttributeValue(el.ref, kAXFocusedAttribute as CFString, kCFBooleanTrue)
    let err = AXUIElementSetAttributeValue(el.ref, kAXValueAttribute as CFString, value as CFTypeRef)
    guard err == .success else { throw BridgeError.actionFailed("setValue failed (AXError \(err.rawValue)); the element may be read-only") }
  }

  public func raise(app: String, windowId: Int?) throws {
    let a = try resolve(app)
    // Activate the app first: AXRaise on a background app's window is only
    // honoured once the app is active. This works across Spaces, which is the
    // whole reason the screenshot approach lost Brave.
    a.activate(options: [])
    // Activation switches Spaces asynchronously. Snapshotting before the switch
    // lands sees the menu bar and nothing else (measured), so wait — briefly —
    // for a window to become listable.
    let root = appElement(a)
    let deadline = Date().addingTimeInterval(2.0)
    while Date() < deadline {
      var v: CFTypeRef?
      if AXUIElementCopyAttributeValue(root.ref, kAXWindowsAttribute as CFString, &v) == .success, !axElements(v).isEmpty { break }
      usleep(50_000)
    }
    if let id = windowId {
      guard let w = elements[a.processIdentifier]?[id] else { throw BridgeError.noSuchWindow(id) }
      let err = AXUIElementPerformAction(w.ref, kAXRaiseAction as CFString)
      guard err == .success else { throw BridgeError.actionFailed("raise failed (AXError \(err.rawValue))") }
    }
  }
}
