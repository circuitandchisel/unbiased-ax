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
  /// Every window of each process, on any Space. Only consulted once the
  /// self-check has passed; see WindowMap.selfCheck.
  private var windowMaps: [pid_t: WindowMap] = [:]
  /// The self-check's verdict, once it has one. nil is "could not decide yet"
  /// — not trusted, or no app to witness with — and is asked again, at most
  /// every `selfCheckRetry`, so a bridge started before the Accessibility
  /// grant turns cross-Space on without a restart.
  private var crossSpaceVerdict: Bool? = nil
  private var crossSpaceNextTry = Date.distantPast
  private static let selfCheckRetry: TimeInterval = 30

  public init() {}

  public func isTrusted() -> Bool { AXIsProcessTrusted() }

  public func crossSpace() -> Bool {
    if let v = crossSpaceVerdict { return v }
    guard AXIsProcessTrusted(), Date() >= crossSpaceNextTry else { return false }
    crossSpaceNextTry = Date().addingTimeInterval(Self.selfCheckRetry)
    let v = WindowMap.selfCheck()
    crossSpaceVerdict = v
    return v ?? false
  }

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
    AXUIElementSetMessagingTimeout(e, RemoteToken.messagingTimeout)
    return AXElement(ref: e)
  }

  /// The windows AXWindows lists — the current Space — as elements.
  private func publicWindows(_ a: NSRunningApplication) throws -> [AXElement] {
    let root = appElement(a)
    var v: CFTypeRef?
    let err = AXUIElementCopyAttributeValue(root.ref, kAXWindowsAttribute as CFString, &v)
    if LiveSource.debug {
      FileHandle.standardError.write("[ax] AXWindows for \(a.localizedName ?? "?"): AXError \(err.rawValue), \(axElements(v).count) element(s)\n".data(using: .utf8)!)
    }
    if err == .cannotComplete { throw BridgeError.timeout("\(a.localizedName ?? "the app") did not list its windows") }
    guard err == .success else { return [] }
    return axElements(v).map(AXElement.init)
  }

  /// Real windows on other Spaces: what the window server lists that AXWindows
  /// does not. Empty until the self-check has passed. RemoteToken sets the
  /// messaging timeout on every element it mints, and the scan aborts on the
  /// first timeout, so this cannot hang either.
  private func offSpaceWindows(_ a: NSRunningApplication, here: [AXElement]) -> [AXElement] {
    guard crossSpace() else { return [] }
    var map = windowMaps[a.processIdentifier] ?? WindowMap()
    map.refresh(pid: a.processIdentifier)
    windowMaps[a.processIdentifier] = map
    return map.elements.filter { !here.contains($0) }
  }

  public func windows(app: String) throws -> [WindowInfo] {
    let a = try resolve(app)
    let here = try publicWindows(a)
    let elsewhere = offSpaceWindows(a, here: here)
    let src = LiveSource()
    var reg = registries[a.processIdentifier] ?? IdRegistry()
    var out: [WindowInfo] = []
    // One window-server listing for the whole loop: the parked check is a
    // comparison against it, and asking per window would be N scans.
    let surfaces = Self.surfaceSizes()
    // parenthesised: a trailing closure in a for-in sequence draws a confusable-with-body warning
    for (el, onSpace) in (here.map { ($0, true) } + elsewhere.map { ($0, false) }) {
      guard let at = src.attributes(of: el) else { continue }
      var minimized: CFTypeRef?
      AXUIElementCopyAttributeValue(el.ref, kAXMinimizedAttribute as CFString, &minimized)
      let id = reg.id(for: el)
      elements[a.processIdentifier, default: [:]][id] = el
      out.append(WindowInfo(id: id, title: at.title ?? "", x: at.x, y: at.y, width: at.width, height: at.height,
                            minimized: (minimized as? Bool) ?? false, focused: at.focused, onSpace: onSpace,
                            parked: Self.isParked(el, width: at.width, height: at.height, in: surfaces)))
    }
    registries[a.processIdentifier] = reg
    return out
  }

  /// With cross-Space on: real windows not on this Space, which ARE in the
  /// tree. Without it: everything the window server lists that is not on
  /// screen — the only signal there was, inflated by the system strips.
  public func offscreenWindows(app: String) throws -> Int {
    let a = try resolve(app)
    if crossSpace() {
      // annotation, not the read: an AXWindows timeout here must not sink a tree that already came back
      let here = (try? publicWindows(a)) ?? []
      let mapped = offSpaceWindows(a, here: here)
      // Nothing readable and nothing mapped: the app may have no window, or one
      // the scan has not reached (never vended, or the first look aborted).
      // Count what the window server lists so the caller can say "read again".
      return here.isEmpty && mapped.isEmpty ? WindowMap.unreachableCandidates(pid: a.processIdentifier) : mapped.count
    }
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
      throw BridgeError.actionFailed("\(a.localizedName ?? app) did not answer the Accessibility API (AXError \(probeErr.rawValue)). -25204 is cannotComplete: the app is busy, or is not accessibility-enabled; -25211 is apiDisabled; -25208 is notImplemented; -25202 is invalid element.")
    }
    if LiveSource.debug, let at = LiveSource(appRoot: root).attributes(of: root) {
      FileHandle.standardError.write("[ax] root: role=\(at.role) title=\(at.title ?? "-") size=\(at.width)x\(at.height) geometryKnown=\(at.geometryKnown) children=\(LiveSource(appRoot: root).children(of: root).count)\n".data(using: .utf8)!)
    }
    var reg = registries[a.processIdentifier] ?? IdRegistry()
    let extra = crossSpace() ? offSpaceWindows(a, here: (try? publicWindows(a)) ?? []) : []
    let snap = Snapshot.build(root: root, source: LiveSource(appRoot: root, extraWindows: extra), registry: &reg, options: options)
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

  /// Letters and digits on a US layout. Virtual key codes are positions on the
  /// keyboard rather than characters, so these are the US positions; a layout
  /// that moves them would send the wrong character. Accepted deliberately:
  /// the reason letters exist here is app SHORTCUTS, which are matched by
  /// position too, so `p` selects Figma's pen on any layout where `p` is where
  /// US keyboards put it.
  static let letterCodes: [String: CGKeyCode] = [
    "a": 0, "b": 11, "c": 8, "d": 2, "e": 14, "f": 3, "g": 5, "h": 4, "i": 34, "j": 38, "k": 40,
    "l": 37, "m": 46, "n": 45, "o": 31, "p": 35, "q": 12, "r": 15, "s": 1, "t": 17, "u": 32,
    "v": 9, "w": 13, "x": 7, "y": 16, "z": 6,
    "0": 29, "1": 18, "2": 19, "3": 20, "4": 21, "5": 23, "6": 22, "7": 26, "8": 28, "9": 25,
  ]

  static func flags(for modifiers: [String]) -> CGEventFlags {
    var f: CGEventFlags = []
    for m in modifiers {
      switch m {
      case "command": f.insert(.maskCommand)
      case "shift": f.insert(.maskShift)
      case "option": f.insert(.maskAlternate)
      case "control": f.insert(.maskControl)
      default: break
      }
    }
    return f
  }

  public func pressKey(app: String, key: String, modifiers: [String], focusId: Int?) throws {
    let a = try resolve(app)
    // Focus first when the caller named a target: a key event goes to whatever
    // holds keyboard focus, and "space to play" in an omnibox types a space.
    if let id = focusId {
      let (_, el) = try element(app, id)
      AXUIElementSetAttributeValue(el.ref, kAXFocusedAttribute as CFString, kCFBooleanTrue)
    }
    guard let code = Self.keyCodes[key] ?? Self.letterCodes[key] else {
      throw BridgeError.badParams("Unknown key \"\(key)\".")
    }
    // Posted to the pid, not the system: it reaches the app whether or not it
    // is frontmost, and cannot land in some other window by accident.
    guard let down = CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: true),
          let up = CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: false) else {
      throw BridgeError.actionFailed("could not create key event")
    }
    let f = Self.flags(for: modifiers)
    if !f.isEmpty {
      down.flags = f
      up.flags = f
    }
    down.postToPid(a.processIdentifier)
    up.postToPid(a.processIdentifier)
  }

  /// Pointer input inside one element. See the protocol for why the caller
  /// passes fractions rather than pixels.
  ///
  /// Posted GLOBALLY, not to the pid, and that is the whole reason this verb
  /// has a visibility requirement. Measured: mouse events posted to a process
  /// do nothing to a canvas — the app hit-tests them against what is actually
  /// on screen. So the events go to the HID tap at real screen coordinates,
  /// which means the window has to be where those coordinates are. A parked or
  /// off-Space window is refused rather than clicked at blindly, because the
  /// click would land on whatever is at that spot instead.
  public func pointer(app: String, id: Int, path: [(x: Double, y: Double)], hold: Bool, modifiers: [String]) throws -> [CGPoint] {
    let a = try resolve(app)
    let (_, el) = try element(app, id)
    guard let frame = Self.frame(of: el) else {
      throw BridgeError.actionFailed("element \(id) does not report a position and size, so there is nothing to aim inside")
    }
    guard frame.width > 1, frame.height > 1 else {
      throw BridgeError.actionFailed("element \(id) is \(Int(frame.width))x\(Int(frame.height)); too small to aim inside")
    }
    if let parked = parkedWindow(app: app) {
      throw BridgeError.actionFailed("\(a.localizedName ?? app)'s window is parked by Stage Manager at \(parked.actual.w)x\(parked.actual.h), so it is not where these coordinates are on screen and a click would land on whatever is. Pointer input is the one thing that needs the window really visible: raise the app first, and say so to the user, or do this with the keyboard and menus instead.")
    }
    if let wins = try? windows(app: app), wins.allSatisfy({ !$0.onSpace }) {
      throw BridgeError.actionFailed("\(a.localizedName ?? app) has no window on this Space, so a click at these coordinates would land on another app. Raise it first, or use the keyboard and menus.")
    }
    let points = path.map { CGPoint(x: frame.minX + frame.width * $0.x, y: frame.minY + frame.height * $0.y) }
    let f = Self.flags(for: modifiers)
    func post(_ type: CGEventType, _ at: CGPoint) {
      guard let ev = CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: at, mouseButton: .left) else { return }
      ev.setIntegerValueField(.mouseEventClickState, value: 1)
      if !f.isEmpty { ev.flags = f }
      ev.post(tap: .cghidEventTap)
      usleep(Self.pointerStepUs)
    }
    if hold, points.count > 1 {
      post(.mouseMoved, points[0])
      post(.leftMouseDown, points[0])
      for pt in points.dropFirst() { post(.leftMouseDragged, pt) }
      post(.leftMouseUp, points[points.count - 1])
    } else {
      for pt in points {
        post(.mouseMoved, pt)
        post(.leftMouseDown, pt)
        post(.leftMouseUp, pt)
      }
    }
    return points
  }

  /// Between events. Apps that build a path from clicks drop points sent
  /// faster than they redraw; measured at 70ms in the comparison run.
  static let pointerStepUs: UInt32 = 70_000

  static func frame(of el: AXElement) -> CGRect? {
    var posRef: CFTypeRef?
    var sizeRef: CFTypeRef?
    guard AXUIElementCopyAttributeValue(el.ref, kAXPositionAttribute as CFString, &posRef) == .success,
          AXUIElementCopyAttributeValue(el.ref, kAXSizeAttribute as CFString, &sizeRef) == .success,
          let posVal = posRef as! AXValue?, let sizeVal = sizeRef as! AXValue? else { return nil }
    var origin = CGPoint.zero
    var size = CGSize.zero
    guard AXValueGetValue(posVal, .cgPoint, &origin), AXValueGetValue(sizeVal, .cgSize, &size) else { return nil }
    return CGRect(origin: origin, size: size)
  }

  /// Launch by name or bundle id, then wait until the app is actually readable
  /// rather than merely running. `open` returns as soon as the process starts,
  /// which is well before AXWindows lists anything — a model that launched and
  /// read immediately got an empty tree and concluded the tool did not work.
  /// Waiting here is cheaper than teaching every caller to poll.
  ///
  /// This shells out to /usr/bin/open rather than NSWorkspace, deliberately.
  /// NSWorkspace.openApplication delivers its result on the main run loop,
  /// which a stdio tool does not run: the app launched and the completion
  /// handler never fired, so a successful launch reported failure. `open` also
  /// gets name lookup right for free — Maps lives in /System/Applications, and
  /// hand-rolled directory scanning is a list of places to forget.
  public func launch(app: String, timeout: Double) throws -> Bool {
    // NOT short-circuited when the app is already running. It IS
    // short-circuited when a readable window exists — on this Space, or
    // anywhere once cross-Space is on — because then there is nothing to open
    // and no reason to touch focus.
    let alreadyHere = ((try? windows(app: app)) ?? []).isEmpty == false
    if alreadyHere { return true } // a readable window exists; do not touch focus

    let proc = Process()
    proc.executableURL = URL(fileURLWithPath: "/usr/bin/open")
    // A bundle id needs -b; everything else is a name or a path for -a. Guessing
    // by shape is safe here because the two flags fail loudly, not silently.
    let looksLikeBundleId = app.contains(".") && !app.hasSuffix(".app") && !app.contains("/")
    // Foreground only when the tree is blind to other Spaces: a background
    // launch (-g) leaves the new window wherever the app puts it, and without
    // the remote-token path that window is NOT in the tree — measured: a
    // 1-element tree and an off-Space hint. With cross-Space on, -g is the
    // right call: the window is readable wherever it lands and the user keeps
    // their screen, which is the whole point.
    proc.arguments = (crossSpace() ? ["-g"] : []) + [looksLikeBundleId ? "-b" : "-a", app]
    proc.standardOutput = FileHandle.nullDevice
    proc.standardError = FileHandle.nullDevice
    do { try proc.run() } catch { return false }
    proc.waitUntilExit()
    guard proc.terminationStatus == 0 else { return false }

    // READABLE, not merely running. `windows` includes off-Space windows when
    // cross-Space is on, so "readable" means "anywhere"; without it, it means
    // "on this Space", and activating a window that lives elsewhere means
    // macOS has a Space switch to finish first.
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
      if let a = try? resolve(app), let wins = try? windows(app: String(a.processIdentifier)), !wins.isEmpty {
        return true
      }
      Thread.sleep(forTimeInterval: 0.2)
    }
    // Out of time. The app IS running, so say so rather than reporting a
    // failed launch — the read that follows carries the off-Space hint, which
    // tells the caller to raise it.
    return (try? resolve(app)) != nil
  }

  /// Why a press did nothing, when the bridge can tell. Measured end to end
  /// on 2026-09-05: with Stage Manager on, the moment another app is active
  /// macOS parks a background app's window into the side strip as a thumbnail
  /// — 108x104 while the Accessibility API still reports 1024x768. At that
  /// size the app stops hit-testing its SwiftUI-hosted controls, so list rows,
  /// card buttons and mode tabs accept AXPress and do nothing, and a picture
  /// of the window is blank. Posted keys and menu bar items are unaffected,
  /// because neither goes through the window's hit-testing.
  ///
  /// Raising is deliberately NOT offered: it un-parks the window only while
  /// the app is in front, re-parks it the moment focus moves on, and takes
  /// the user's screen to do it — the exact thing this bridge exists to avoid.
  public func unresponsiveHint(app: String) -> String? {
    guard let a = try? resolve(app), let shrunk = parkedWindow(app: app) else { return nil }
    let name = a.localizedName ?? app
    let sizes = "\(shrunk.actual.w)x\(shrunk.actual.h), though the tree describes it at \(shrunk.expected.w)x\(shrunk.expected.h)"
    guard Self.stageManagerOn() else {
      return "\(name)'s window is only \(sizes). At that size the app stops hit-testing its list rows, card buttons and tabs, so presses on them do nothing. Use the keyboard instead: from a search field, down and up move through results and return opens one. Menu bar items in this tree also work."
    }
    return "Stage Manager has parked \(name)'s window in the side strip as a thumbnail: \(sizes). Every app the user is not looking at is parked this way, and a thumbnail cannot be clicked, so presses on rows, card buttons and tabs are accepted and do nothing, and a picture of the window is blank. The window is READABLE but not reliably INTERACTABLE, which is the distinction that matters: what you read is exact, what you press may not land. Two paths do work and are enough to finish the task. To choose from a list: from a search field, down and up move through the results and return opens one; escape closes. To reach a control you cannot press: ask the app for the finished action in its search field — set the field to the whole intent rather than the object, \"directions to X\" instead of \"X\", and commit with those same keys. Menu bar items in this tree work too. Do not raise the app — the window re-parks as soon as focus moves on, and raising takes over the user's screen. Moving the window to another Space, resizing it, or hunting through Window > Move & Resize does not help and has been measured costing five turns: parking follows which app is ACTIVE, not where the window sits. If this keeps getting in the way, the user can turn Stage Manager off in System Settings > Desktop & Dock."
  }

  /// Whether Stage Manager is on. It parks every inactive app's windows into
  /// the side strip as thumbnails, which is what makes them unclickable.
  static func stageManagerOn() -> Bool {
    (CFPreferencesCopyAppValue("GloballyEnabled" as CFString, "com.apple.WindowManager" as CFString) as? Bool) ?? false
  }

  /// Window-server id -> the size of the surface it is actually showing.
  static func surfaceSizes() -> [CGWindowID: CGSize] {
    var out: [CGWindowID: CGSize] = [:]
    for w in (CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID) as? [[String: Any]]) ?? [] {
      guard let n = w[kCGWindowNumber as String] as? Int,
            let b = w[kCGWindowBounds as String] as? [String: Any],
            let width = b["Width"] as? Double, let height = b["Height"] as? Double else { continue }
      out[CGWindowID(n)] = CGSize(width: width, height: height)
    }
    return out
  }

  /// Half the described extent in BOTH directions is not a resize, it is a
  /// thumbnail: the measured case was 108x104 against 1024x768. Windows too
  /// small to say anything about are left alone.
  static func isParked(_ el: AXElement, width: Int, height: Int, in surfaces: [CGWindowID: CGSize]) -> Bool {
    guard width > 200, height > 200, let wid = RemoteToken.windowId(of: el.ref), let actual = surfaces[wid] else { return false }
    return actual.width < Double(width) / 2 && actual.height < Double(height) / 2
  }

  /// The first parked window of an app, with the sizes, for the message that
  /// explains why a press did nothing.
  func parkedWindow(app: String) -> (expected: (w: Int, h: Int), actual: (w: Int, h: Int))? {
    guard let wins = try? windows(app: app), let a = try? resolve(app) else { return nil }
    let surfaces = Self.surfaceSizes()
    for win in wins where win.parked && !win.minimized {
      guard let el = elements[a.processIdentifier]?[win.id], let wid = RemoteToken.windowId(of: el.ref),
            let actual = surfaces[wid] else { continue }
      return ((win.width, win.height), (Int(actual.width), Int(actual.height)))
    }
    return nil
  }

  /// The Accessibility API has no scroll verb — kAXScrollToVisibleAction moves
  /// to a known element, which is no help for "show me more of this list". So
  /// post real scroll-wheel events at the element's midpoint, to the pid, the
  /// same way pressKey does: it reaches a background app and cannot land in
  /// someone else's window.
  public func scroll(app: String, id: Int, dx: Int, dy: Int) throws {
    let a = try resolve(app)
    let (_, el) = try element(app, id)
    // Move the pointer over the target first: a scroll event is delivered to
    // whatever is under the cursor, so without this it scrolls the wrong view.
    var posRef: CFTypeRef?
    var sizeRef: CFTypeRef?
    if AXUIElementCopyAttributeValue(el.ref, kAXPositionAttribute as CFString, &posRef) == .success,
       AXUIElementCopyAttributeValue(el.ref, kAXSizeAttribute as CFString, &sizeRef) == .success,
       let posVal = posRef as! AXValue?, let sizeVal = sizeRef as! AXValue? {
      var origin = CGPoint.zero
      var size = CGSize.zero
      if AXValueGetValue(posVal, .cgPoint, &origin), AXValueGetValue(sizeVal, .cgSize, &size) {
        let mid = CGPoint(x: origin.x + size.width / 2, y: origin.y + size.height / 2)
        if let move = CGEvent(mouseEventSource: nil, mouseType: .mouseMoved, mouseCursorPosition: mid, mouseButton: .left) {
          move.postToPid(a.processIdentifier)
        }
      }
    }
    guard let ev = CGEvent(scrollWheelEvent2Source: nil, units: .line, wheelCount: 2,
                           wheel1: Int32(dy), wheel2: Int32(dx), wheel3: 0) else {
      throw BridgeError.actionFailed("could not create scroll event")
    }
    ev.postToPid(a.processIdentifier)
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

  public func screenshot(app: String, windowId: Int?) throws -> WindowShot {
    let a = try resolve(app)
    let wins = try windows(app: app)
    guard !wins.isEmpty else { throw BridgeError.actionFailed("\(a.localizedName ?? app) has no window to photograph") }
    let target: WindowInfo
    if let id = windowId {
      guard let w = wins.first(where: { $0.id == id }) else { throw BridgeError.noSuchWindow(id) }
      target = w
    } else {
      target = wins.first(where: \.focused) ?? wins.first(where: \.onSpace) ?? wins[0]
    }
    guard let el = elements[a.processIdentifier]?[target.id], let cg = RemoteToken.windowId(of: el.ref) else {
      throw BridgeError.actionFailed("could not map window \(target.id) to the window server")
    }
    return try WindowCapture.capture(cgWindow: cg, info: target)
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
