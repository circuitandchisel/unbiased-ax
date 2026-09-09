import Foundation
import AXModel

/// A backend with two apps and a fixed tree, enough to drive every method.
final class FakeBackend: Backend {
  var trusted = true
  var acted: [(app: String, id: Int, action: String)] = []
  var setValues: [(app: String, id: Int, value: String)] = []
  var lastOptions: SnapshotOptions?
  var offscreen = 0
  var hideWindows = false
  /// Models a window the window server lists that the scan has not reached:
  /// `windows` is empty even with cross-Space on.
  var unreachable = false
  /// Models the live adapter having proved the remote-token path. With it on,
  /// a "hidden" window is still listed, flagged as on another Space.
  var crossSpaceOn = false
  var keys: [(app: String, key: String)] = []
  var registries: [String: IdRegistry] = [:]
  /// The baseline: the OK button and the address field the tests act on, plus
  /// padding so a "lost 30 nodes" shrink is expressible at all.
  let tree = group("w", [button("w/ok", "OK"),
                         FakeNode("w/url", Attributes(role: "text field", title: "Address", value: "a.com", width: 300, height: 20))]
                        + (0..<38).map { button("w/pad\($0)", "Pad \($0)") },
                   title: "Win")

  func isTrusted() -> Bool { trusted }
  func crossSpace() -> Bool { crossSpaceOn }
  /// False models an app that is not running yet, so a launch is cold.
  var braveRunning = true
  func apps() -> [AppInfo] {
    (braveRunning ? [AppInfo(pid: 10, name: "Brave Browser", bundleId: "com.brave.Browser", frontmost: true)] : [])
      + [AppInfo(pid: 11, name: "Finder", bundleId: "com.apple.finder", frontmost: false)]
  }
  func windows(app: String) throws -> [WindowInfo] {
    guard app == "Brave Browser" else { throw BridgeError.noSuchApp(app) }
    if unreachable { return [] }
    if hideWindows && !crossSpaceOn { return [] }
    let win = WindowInfo(id: 1, title: "YouTube - Brave", x: 0, y: 0, width: 1200, height: 800, minimized: false, focused: true, onSpace: !hideWindows, parked: parkedWindow)
    return [win]
  }
  func snapshot(app: String, options: SnapshotOptions) throws -> Snapshot {
    guard app == "Brave Browser" else { throw BridgeError.noSuchApp(app) }
    lastOptions = options
    snapshotCount += 1
    // Once the app has "rendered", the tree gains a node so the diff is real.
    let late = snapshotsUntilChange > 0 && snapshotCount > snapshotsUntilChange
    // Between the baseline and the late render the tree can pass through a
    // smaller state — a result list that collapsed before its place card came.
    let shrunk = !late && shrunkUntilSnapshot > 0 && snapshotCount > 1 && snapshotCount <= shrunkUntilSnapshot
    var reg = registries[app] ?? IdRegistry()
    defer { registries[app] = reg }
    if twoOKs {
      let ambiguous = group("w", [button("w/ok-a", "OK"), button("w/ok-b", "OK")], title: "Win")
      return Snapshot.build(root: ambiguous, source: FakeSource(), registry: &reg, options: options)
    }
    if rebuildOK {
      let rebuilt = group("w", [button("w/ok-rebuilt", "OK"),
                                FakeNode("w/url", Attributes(role: "text field", title: "Address", value: "a.com", width: 300, height: 20))],
                          title: "Win")
      return Snapshot.build(root: rebuilt, source: FakeSource(), registry: &reg, options: options)
    }
    let base = extraNodes
    let root = late
      ? group("w", [button("w/ok", "OK"),
                    FakeNode("w/url", Attributes(role: "text field", title: "Address", value: "a.com", width: 300, height: 20)),
                    button("w/late", "Result")]
                   + (0..<38).map { button("w/pad\($0)", "Pad \($0)") } + base, title: "Win")
      : shrunk ? group("w", (0..<max(0, 40 - shrinkBy)).map { button("w/pad\($0)", "Pad \($0)") } + base, title: "Win")
      : (base.isEmpty ? tree : group("w", [button("w/ok", "OK"),
                                           FakeNode("w/url", Attributes(role: "text field", title: "Address", value: "a.com", width: 300, height: 20))]
                                          + (0..<38).map { button("w/pad\($0)", "Pad \($0)") } + base, title: "Win"))
    return Snapshot.build(root: root, source: FakeSource(), registry: &reg, options: options)
  }
  func offscreenWindows(app: String) throws -> Int { offscreen }
  var iconPNG: Data? = Data([0x89, 0x50, 0x4E, 0x47])
  func appIcon(app: String) throws -> Data {
    guard let d = iconPNG else { throw BridgeError.noSuchApp(app) }
    return d
  }
  var focused: [(app: String, id: Int)] = []
  var keyMods: [[String]] = []
  /// When set, the next key press empties `extraNodes`: the app deleted them.
  var keyRemovesExtra = false
  func pressKey(app: String, key: String, modifiers: [String], focusId: Int?) throws {
    if keyRemovesExtra { extraNodes = []; keyRemovesExtra = false }
    if let id = focusId { focused.append((app, id)) }
    keys.append((app, key))
    keyMods.append(modifiers)
  }
  /// What the dispatcher asked for, and what it will be told landed. The frame
  /// is fixed at 0,0 200x100 so a fraction maps to an obvious number.
  var pointerCalls: [(app: String, id: Int, path: [(x: Double, y: Double)], hold: Bool, modifiers: [String])] = []
  var pointerFails: String? = nil
  func pointer(app: String, id: Int, path: [(x: Double, y: Double)], hold: Bool, modifiers: [String], clicks: Int) throws -> [CGPoint] {
    if let why = pointerFails { throw BridgeError.actionFailed(why) }
    guard app == "Brave Browser" else { throw BridgeError.noSuchApp(app) }
    pointerCalls.append((app, id, path, hold, modifiers))
    clickCounts.append(clicks)
    let pts = path.map { CGPoint(x: 200 * $0.x, y: 100 * $0.y) }
    // Same rule as the live backend: single clicks are paced, and a repeated
    // pixel is not clicked twice.
    return (!hold && clicks == 1) ? ClickPacing.plan(pts).clicks.map(\.point) : pts
  }
  var typed: [(app: String, text: String, focusId: Int?)] = []
  func typeText(app: String, text: String, focusId: Int?) throws {
    typed.append((app, text, focusId))
  }
  /// What the app "says" is under a pointer's first point. Honest by default.
  var pointerHitResult: HitRelation = .inside
  func pointerHit(app: String, id: Int, path: [(x: Double, y: Double)]) throws -> HitRelation { pointerHitResult }
  /// Where keyboard focus "is". A field by default, so free typing lands.
  var focusedControlValue: (role: String, title: String?)? = (role: "text field", title: "Address")
  func focusedControl(app: String) throws -> (role: String, title: String?)? { focusedControlValue }
  var clickCounts: [Int] = []
  var keepFrontSeen: [Bool] = []
  func perform(app: String, id: Int, action: String, keepFront: Bool) throws {
    keepFrontSeen.append(keepFront); acted.append((app, id, action))
  }
  /// What the field holds now. The fake echoes a write back, so verification
  /// passes by default and only a test that ASKS for a mismatch sees one.
  var storedValues: [Int: String] = [:]
  /// What value() reports instead of the echo — a field that rounded, appended
  /// or ignored the write.
  var valueOverrides: [Int: String] = [:]
  func setValue(app: String, id: Int, value: String, keepFront: Bool) throws {
    keepFrontSeen.append(keepFront); setValues.append((app, id, value)); storedValues[id] = value
  }
  var valueReads: [Int] = []
  /// An element that exposes no value at all — a button, a group.
  var valueIsNil = false
  func value(app: String, id: Int) throws -> String? {
    valueReads.append(id)
    if valueIsNil { return nil }
    return valueOverrides[id] ?? storedValues[id]
  }
  var raised: [(app: String, windowId: Int?)] = []
  func raise(app: String, windowId: Int?) throws {
    raised.append((app, windowId))}
  var launched: [String] = []
  var launchSucceeds = true
  func launch(app: String, timeout: Double) throws -> Bool {
    launched.append(app)
    return launchSucceeds
  }
  var shotRequests: [(app: String, windowId: Int?)] = []
  /// Models Stage Manager: the window is listed and readable but its surface
  /// is a thumbnail, so presses on it do nothing.
  var parkedWindow = false
  var unresponsiveWhy: String? = nil
  func unresponsiveHint(app: String) -> String? { unresponsiveWhy ?? (parkedWindow ? "Stage Manager has parked it" : nil) }
  var blankShot = false
  func screenshot(app: String, windowId: Int?) throws -> WindowShot {
    guard app == "Brave Browser" else { throw BridgeError.noSuchApp(app) }
    shotRequests.append((app, windowId))
    return WindowShot(image: Data([0xFF, 0xD8, 0xFF]), mime: "image/jpeg", width: 1200, height: 800, windowId: windowId ?? 1, onSpace: !hideWindows, blank: blankShot)
  }
  /// Snapshots before the tree changes. Models an app that renders its
  /// response a beat after the action returns — which is every real app.
  var snapshotsUntilChange = 0
  /// Snapshots 2...N show a tree that has only lost nodes; see snapshot().
  var shrunkUntilSnapshot = 0
  /// How many nodes the shrunk tree loses. A panel closing loses a couple; a
  /// result list collapsing loses tens, and only the second is a transition.
  var shrinkBy = 1
  /// Models an app tearing a control down and building it again: same role and
  /// title, new identity, so the registry gives it a new id.
  var rebuildOK = false
  /// Two controls that match each other: re-finding must refuse, not pick.
  var twoOKs = false
  var snapshotCount = 0
  var scrolls: [(app: String, id: Int, dx: Int, dy: Int)] = []
  /// Extra children hung off the window, for tests that need particular roles.
  var extraNodes: [FakeNode] = []
  func scroll(app: String, id: Int, dx: Int, dy: Int) throws { scrolls.append((app, id, dx, dy)) }
}

func runDispatcherTests() {
  print("Dispatcher")
  func call(_ d: Dispatcher, _ json: String) -> String { d.handle(line: json) }

  test("hello reports the protocol version and trust state") {
    let out = call(Dispatcher(backend: FakeBackend()), #"{"id":1,"method":"hello"}"#)
    try expect(out.contains(#""protocolVersion":1"#), out)
    try expect(out.contains(#""trusted":true"#), out)
  }
  test("malformed JSON is an error response, never a crash") {
    let out = call(Dispatcher(backend: FakeBackend()), "not json")
    try expect(out.contains(#""code":"bad_request""#), out)
  }
  test("an unknown method is reported by name, even when untrusted") {
    let b = FakeBackend(); b.trusted = false
    let out = call(Dispatcher(backend: b), #"{"id":2,"method":"teleport"}"#)
    try expect(out.contains(#""code":"unknown_method""#), out)
    try expect(out.contains("teleport"), out)
  }
  test("every method except hello and apps refuses when not trusted, and says how to fix it") {
    let b = FakeBackend(); b.trusted = false
    let out = call(Dispatcher(backend: b), #"{"id":3,"method":"tree","params":{"app":"Brave Browser"}}"#)
    try expect(out.contains(#""code":"not_trusted""#), out)
    try expect(out.contains("Accessibility"), out)
    try expect(call(Dispatcher(backend: b), #"{"id":4,"method":"apps"}"#).contains("Finder"))
  }
  test("tree returns rendered text, and the second call for the same app is a diff") {
    let d = Dispatcher(backend: FakeBackend())
    let first = call(d, #"{"id":5,"method":"tree","params":{"app":"Brave Browser"}}"#)
    try expect(first.contains(#""tree""#), first)
    try expect(first.contains("OK"), first)
    let second = call(d, #"{"id":6,"method":"tree","params":{"app":"Brave Browser"}}"#)
    try expect(second.contains("(no changes)"), second)
  }
  test("full=true forces a complete tree even when a diff is available") {
    let d = Dispatcher(backend: FakeBackend())
    _ = call(d, #"{"id":7,"method":"tree","params":{"app":"Brave Browser"}}"#)
    let out = call(d, #"{"id":8,"method":"tree","params":{"app":"Brave Browser","full":true}}"#)
    try expect(out.contains(#""tree""#) && !out.contains("(no changes)"), out)
  }
  test("snapshot options reach the backend") {
    let b = FakeBackend(); let d = Dispatcher(backend: b)
    _ = call(d, #"{"id":9,"method":"tree","params":{"app":"Brave Browser","depth":3,"maxElements":40,"interactive":true}}"#)
    try expectEqual(b.lastOptions?.maxDepth, 3)
    try expectEqual(b.lastOptions?.maxElements, 40)
    try expectEqual(b.lastOptions?.interactiveOnly, true)
    try expectEqual(b.lastOptions?.webContent, false, "web content is opt-in")
    _ = call(d, #"{"id":9,"method":"tree","params":{"app":"Brave Browser","web":true}}"#)
    try expectEqual(b.lastOptions?.webContent, true)
  }
  test("an unknown app is a clear error") {
    let out = call(Dispatcher(backend: FakeBackend()), #"{"id":10,"method":"tree","params":{"app":"Nope"}}"#)
    try expect(out.contains(#""code":"no_such_app""#), out)
  }
  test("act performs the action and returns the diff that resulted") {
    let b = FakeBackend(); let d = Dispatcher(backend: b)
    _ = call(d, #"{"id":11,"method":"tree","params":{"app":"Brave Browser"}}"#)
    let out = call(d, #"{"id":12,"method":"act","params":{"app":"Brave Browser","id":2,"action":"press"}}"#)
    try expectEqual(b.acted.count, 1)
    try expectEqual(b.acted.first?.action, "press")
    try expect(out.contains(#""diff""#), out)
  }
  test("act on an id the model never saw is refused, not guessed") {
    let out = call(Dispatcher(backend: FakeBackend()), #"{"id":13,"method":"act","params":{"app":"Brave Browser","id":999,"action":"press"}}"#)
    try expect(out.contains(#""code":"no_such_element""#), out)
  }
  test("setValue writes and returns the diff") {
    let b = FakeBackend(); let d = Dispatcher(backend: b)
    _ = call(d, #"{"id":14,"method":"tree","params":{"app":"Brave Browser"}}"#)
    let out = call(d, #"{"id":15,"method":"setValue","params":{"app":"Brave Browser","id":3,"value":"youtube.com"}}"#)
    try expectEqual(b.setValues.first?.value, "youtube.com")
    try expect(out.contains(#""diff""#), out)
  }
  test("find filters by role and title substring without a full dump") {
    let out = call(Dispatcher(backend: FakeBackend()), #"{"id":16,"method":"find","params":{"app":"Brave Browser","role":"button","title":"ok"}}"#)
    try expect(out.contains("OK"), out)
    try expect(!out.contains("Address"), out)
  }
  test("windows lists titles with geometry, as text a model can read") {
    let out = call(Dispatcher(backend: FakeBackend()), #"{"id":17,"method":"windows","params":{"app":"Brave Browser"}}"#)
    try expect(out.contains("YouTube - Brave"), out)
    try expect(out.contains("1200x800"), out)
  }
  test("windows reports how many are on another Space, and only hints when some are") {
    // Measured: AXWindows lists only the current Space. Brave had 10 windows
    // and 0 on screen, so every tree of it was its menu bar and nothing else.
    let b = FakeBackend(); b.offscreen = 10
    let out = call(Dispatcher(backend: b), #"{"id":17,"method":"windows","params":{"app":"Brave Browser"}}"#)
    try expect(out.contains(#""offscreen":10"#), out)
    try expect(out.contains("hint"), out)
    b.offscreen = 0
    try expect(!call(Dispatcher(backend: b), #"{"id":18,"method":"windows","params":{"app":"Brave Browser"}}"#).contains("hint"))
  }
  test("a key aimed at an element focuses it first — a bare key lands wherever focus happens to be") {
    // Measured: the model sent space to play a video while focus sat in the
    // omnibox, and typed spaces into the address bar instead.
    let b = FakeBackend(); let d = Dispatcher(backend: b)
    _ = call(d, #"{"id":30,"method":"tree","params":{"app":"Brave Browser"}}"#)
    _ = call(d, #"{"id":31,"method":"key","params":{"app":"Brave Browser","key":"space","id":2}}"#)
    try expectEqual(b.focused.first?.id, 2)
    try expectEqual(b.keys.first?.key, "space")
    // An id the model never saw is refused rather than sent somewhere random.
    let bad = call(d, #"{"id":32,"method":"key","params":{"app":"Brave Browser","key":"space","id":999}}"#)
    try expect(bad.contains(#""code":"no_such_element""#), bad)
  }
  test("windows here plus windows elsewhere: work with what is here, do not raise") {
    // The first live failure: the model raised even though the window it
    // needed was already on this Space.
    let b = FakeBackend(); b.offscreen = 5     // FakeBackend always returns one window
    let out = call(Dispatcher(backend: b), #"{"id":33,"method":"windows","params":{"app":"Brave Browser"}}"#)
    try expect(out.contains(#""offscreen":5"#), out)
    try expect(!out.lowercased().contains("call raise"), "must not instruct a raise when a window is here: \(out)")
    try expect(out.lowercased().contains("do not raise"), out)
  }
  test("NO windows here and some elsewhere: say plainly that raise is the only way in") {
    // The second live failure, and the worse one: a hint claiming off-Space
    // windows could still be read sent the model through Spotlight, Dock
    // clicks, Stage Manager and ten shell commands over six minutes. An
    // off-Space window is NOT in the tree — measured: 12 elements, the menu
    // bar, and zero matches for a search.
    let b = FakeBackend(); b.offscreen = 10; b.hideWindows = true
    let out = call(Dispatcher(backend: b), #"{"id":34,"method":"windows","params":{"app":"Brave Browser"}}"#)
    try expect(out.lowercased().contains("raise"), "must send the model to raise: \(out)")
    try expect(!out.lowercased().contains("can still read"), "must not promise what does not work: \(out)")
  }
  test("nothing anywhere: no hint at all") {
    let b = FakeBackend(); b.offscreen = 0
    try expect(!call(Dispatcher(backend: b), #"{"id":35,"method":"windows","params":{"app":"Brave Browser"}}"#).contains("hint"))
  }
  test("key sends a named key to the app and returns the diff — the commit AX cannot express") {
    // Measured: setValue put a URL in Brave's omnibox and confirm reported ok,
    // and nothing navigated. Chromium commits the omnibox on a real Return.
    let b = FakeBackend(); let d = Dispatcher(backend: b)
    let out = call(d, #"{"id":19,"method":"key","params":{"app":"Brave Browser","key":"return"}}"#)
    try expectEqual(b.keys.first?.key, "return")
    try expect(out.contains(#""diff""#), out)
    let bad = call(d, #"{"id":20,"method":"key","params":{"app":"Brave Browser","key":"hyperspace"}}"#)
    try expect(bad.contains(#""code":"bad_params""#) && bad.contains("return"), bad)
  }
  test("icon returns the app's icon as base64 png, so a transcript can show which app a step touched") {
    let out = call(Dispatcher(backend: FakeBackend()), #"{"id":40,"method":"icon","params":{"app":"Brave Browser"}}"#)
    try expect(out.contains(#""png":"iVBORw=="#), out)   // the 4 bytes above, base64
  }
  test("an app with no icon is an error, not an empty string") {
    let b = FakeBackend(); b.iconPNG = nil
    try expect(call(Dispatcher(backend: b), #"{"id":41,"method":"icon","params":{"app":"Nope"}}"#).contains(#""code":"no_such_app""#))
  }
  test("keepFront rides with act and setValue, and defaults OFF") {
    // The switch-per-action was not the actions: measured against a native
    // app, setValue leaves the frontmost app alone. It was restoring focus
    // after each one, which put the target app back on its own Space, so the
    // next read found nothing and raised again. Two fixes fighting.
    let b = FakeBackend(); let d = Dispatcher(backend: b)
    _ = call(d, #"{"id":50,"method":"tree","params":{"app":"Brave Browser"}}"#)
    _ = call(d, #"{"id":51,"method":"act","params":{"app":"Brave Browser","id":2,"action":"press"}}"#)
    try expectEqual(b.keepFrontSeen.last, false, "off by default: restoring after every action causes a switch per action")
    _ = call(d, #"{"id":52,"method":"setValue","params":{"app":"Brave Browser","id":3,"value":"x","keepFront":true}}"#)
    try expectEqual(b.keepFrontSeen.last, true, "a caller can still ask for it")
  }
  test("apps lists running apps with the frontmost marked") {
    let out = call(Dispatcher(backend: FakeBackend()), #"{"id":18,"method":"apps"}"#)
    try expect(out.contains("Brave Browser"), out)
    try expect(out.contains(#""frontmost":true"#), out)
  }
  test("a missing required param is a bad_params error naming the param") {
    let out = call(Dispatcher(backend: FakeBackend()), #"{"id":19,"method":"tree","params":{}}"#)
    try expect(out.contains(#""code":"bad_params""#), out)
    try expect(out.contains("app"), out)
  }
}

func runDesktopReachTests() {
  print("Reaching an app the user has not opened")
  func call(_ d: Dispatcher, _ json: String) -> String { d.handle(line: json) }

  // The failure this fixes: a read of an app whose windows are all elsewhere
  // returns the menu bar and nothing else. Told nothing, a model concludes the
  // tool is broken and leaves for a shell.

  test("a read says so when every window is on another Space") {
    let b = FakeBackend(); b.offscreen = 5; b.hideWindows = true
    let out = call(Dispatcher(backend: b), #"{"id":1,"method":"tree","params":{"app":"Brave Browser"}}"#)
    try expect(out.contains("\"offscreen\":5"), "a read must report the count, not just windows: \(out)")
    try expect(out.contains("call raise for this app first"), "and must say what to do about it: \(out)")
  }

  test("a read does not tell the model to raise when windows are already here") {
    let b = FakeBackend(); b.offscreen = 5 // windows visible AND some elsewhere
    let out = call(Dispatcher(backend: b), #"{"id":1,"method":"tree","params":{"app":"Brave Browser"}}"#)
    try expect(out.contains("do not raise"), "raising when a window is here steals the screen for nothing: \(out)")
  }

  test("a read of an app that is entirely here says nothing about Spaces") {
    let out = call(Dispatcher(backend: FakeBackend()), #"{"id":1,"method":"tree","params":{"app":"Brave Browser"}}"#)
    try expect(!out.contains("hint"), "no hint when there is nothing to hint about: \(out)")
    try expect(out.contains("\"offscreen\":0"), "the count is still reported: \(out)")
  }

  test("find carries the same warning as tree") {
    let b = FakeBackend(); b.offscreen = 3; b.hideWindows = true
    let out = call(Dispatcher(backend: b), #"{"id":1,"method":"find","params":{"app":"Brave Browser","title":"OK"}}"#)
    try expect(out.contains("call raise for this app first"), "a search that finds nothing must say why: \(out)")
  }

  test("launch opens an app and hands back its tree, so the model need not poll") {
    let b = FakeBackend()
    let out = call(Dispatcher(backend: b), #"{"id":1,"method":"launch","params":{"app":"Brave Browser"}}"#)
    try expectEqual(b.launched, ["Brave Browser"], "the app should have been launched")
    try expect(out.contains("\"tree\""), "launch returns the tree: reading is always the next move: \(out)")
    try expect(out.contains("\"ok\":true"), out)
  }

  test("a launch that cannot find the app says so instead of failing silently") {
    let b = FakeBackend(); b.launchSucceeds = false
    let out = call(Dispatcher(backend: b), #"{"id":1,"method":"launch","params":{"app":"Nonesuch"}}"#)
    try expect(out.contains("launch_failed"), out)
    try expect(out.contains("not something this tool can create"), "the model must not retry forever: \(out)")
  }

  test("scroll needs a direction and a known element") {
    let b = FakeBackend()
    let d = Dispatcher(backend: b)
    _ = call(d, #"{"id":1,"method":"tree","params":{"app":"Brave Browser"}}"#) // so ids are known
    let zero = call(d, #"{"id":2,"method":"scroll","params":{"app":"Brave Browser","id":1,"dy":0}}"#)
    try expect(zero.contains("bad_params"), "a scroll of zero is a no-op worth rejecting: \(zero)")
    let ok = call(d, #"{"id":3,"method":"scroll","params":{"app":"Brave Browser","id":1,"dy":-3}}"#)
    try expect(!ok.contains("error"), ok)
    try expectEqual(b.scrolls.count, 1, "one scroll should have reached the backend")
    try expectEqual(b.scrolls.first?.dy ?? 0, -3, "direction must be passed through unchanged")
  }

  test("scroll refuses an id the model never read") {
    let b = FakeBackend()
    let out = call(Dispatcher(backend: b), #"{"id":1,"method":"scroll","params":{"app":"Brave Browser","id":999,"dy":-3}}"#)
    try expect(out.contains("no_such_element"), out)
  }
}

func runSettleTests() {
  print("Waiting for an app to react")
  func call(_ d: Dispatcher, _ json: String) -> String { d.handle(line: json) }

  // Pressing return in Maps' search field returned "(no changes)" while the
  // three results were on their way. The model, told nothing had happened,
  // read again to find out — seven redundant round trips in one task.

  test("an action waits for the app to react before reporting no change") {
    let b = FakeBackend()
    let d = Dispatcher(backend: b)
    _ = call(d, #"{"id":1,"method":"tree","params":{"app":"Brave Browser"}}"#) // baseline
    b.snapshotsUntilChange = 2 // the app renders on the third look
    let out = call(d, #"{"id":2,"method":"key","params":{"app":"Brave Browser","key":"return"}}"#)
    try expect(!out.contains("(no changes)"), "it gave up before the app answered: \(out)")
    try expect(out.contains("Result"), "the late-rendered element should be in the diff: \(out)")
  }

  test("an action whose effect is already visible does not wait") {
    let b = FakeBackend()
    let d = Dispatcher(backend: b)
    _ = call(d, #"{"id":1,"method":"tree","params":{"app":"Brave Browser"}}"#)
    b.snapshotsUntilChange = 1 // changed by the very next look
    let started = Date()
    let out = call(d, #"{"id":2,"method":"act","params":{"app":"Brave Browser","id":1,"action":"press"}}"#)
    let elapsed = Date().timeIntervalSince(started)
    try expect(out.contains("Result"), out)
    // It pays the FLOOR, not the deadline. The floor exists because Maps'
    // search results land at ~477ms and an earlier return reported only the
    // echo of the keystroke that asked for them.
    try expect(elapsed < 1.2, "a visible change must not pay the full deadline (took \(elapsed)s)")
    try expect(elapsed >= 0.5, "the floor is the point — returning sooner reports a half-rendered app (took \(elapsed)s)")
  }

  test("an action that genuinely changes nothing still says so, and bounds the wait") {
    let b = FakeBackend()
    let d = Dispatcher(backend: b)
    _ = call(d, #"{"id":1,"method":"tree","params":{"app":"Brave Browser"}}"#)
    let started = Date()
    let out = call(d, #"{"id":2,"method":"act","params":{"app":"Brave Browser","id":1,"action":"press"}}"#)
    let elapsed = Date().timeIntervalSince(started)
    try expect(out.contains("(no changes)"), out)
    try expect(elapsed < 3.0, "the wait must be bounded (took \(elapsed)s)")
    try expect(out.contains(#""waitedMs""#), "the result says how long it waited: \(out)")
  }

  // Pressing a Maps search result: the list collapsed at ~300ms and the tree
  // went quiet; the place card rendered ~2.5s after the press. Reporting the
  // collapse alone cost three model turns.

  test("a tree that has only shrunk is in transition: the action waits for what replaces it") {
    let b = FakeBackend()
    let d = Dispatcher(backend: b)
    _ = call(d, #"{"id":1,"method":"tree","params":{"app":"Brave Browser"}}"#)
    b.shrunkUntilSnapshot = 18 // ~1.7s of collapsed list at one look per 100ms
    b.shrinkBy = 30            // a whole result list, not a tidying panel
    b.snapshotsUntilChange = 18 // then the card
    let out = call(d, #"{"id":2,"method":"act","params":{"app":"Brave Browser","id":1,"action":"press"}}"#)
    try expect(out.contains("Result"), "the replacement should be in the diff, not just the collapse: \(out)")
  }

  test("a tree that shrinks and stays shrunk still reports the removal, within the longer bound") {
    let b = FakeBackend()
    let d = Dispatcher(backend: b)
    _ = call(d, #"{"id":1,"method":"tree","params":{"app":"Brave Browser"}}"#)
    b.shrunkUntilSnapshot = 1_000
    b.shrinkBy = 30 // a whole list, which is what buys the longer bound
    let started = Date()
    let out = call(d, #"{"id":2,"method":"act","params":{"app":"Brave Browser","id":1,"action":"press"}}"#)
    let elapsed = Date().timeIntervalSince(started)
    try expect(out.contains("removed"), out)
    try expect(elapsed >= 3.3 && elapsed < 4.5, "the shrunk-tree bound is 3.5s (took \(elapsed)s)")
  }
}

func runRefusedActionTests() {
  print("Refusing an action the element does not list")
  func call(_ d: Dispatcher, _ json: String) -> String { d.handle(line: json) }

  test("an action the element does not list is refused with what it does offer") {
    let b = FakeBackend()
    let d = Dispatcher(backend: b)
    let tree = call(d, #"{"id":1,"method":"tree","params":{"app":"Brave Browser"}}"#)
    // The element that lists press, by the id at the front of its line.
    guard let line = tree.components(separatedBy: "\\n").first(where: { $0.contains("{press}") }),
          let id = Int(line.trimmingCharacters(in: .whitespaces).prefix { $0.isNumber }) else { try expect(false, "no element lists press: \(tree)"); return }
    let out = call(d, #"{"id":2,"method":"act","params":{"app":"Brave Browser","id":\#(id),"action":"show menu"}}"#)
    try expect(out.contains("action_failed") && out.contains("does not offer") && out.contains("{press}"), out)
    try expectEqual(b.acted.count, 0, "nothing was tried")
  }

  test("a listed action goes through, and an element with no list is not second-guessed") {
    let b = FakeBackend()
    let d = Dispatcher(backend: b)
    let tree = call(d, #"{"id":1,"method":"tree","params":{"app":"Brave Browser"}}"#)
    guard let line = tree.components(separatedBy: "\\n").first(where: { $0.contains("{press}") }),
          let id = Int(line.trimmingCharacters(in: .whitespaces).prefix { $0.isNumber }) else { try expect(false, "no element lists press: \(tree)"); return }
    let ok = call(d, #"{"id":2,"method":"act","params":{"app":"Brave Browser","id":\#(id),"action":"press"}}"#)
    try expect(ok.contains(#""ok":true"#), ok)
    // id 1 is the application node, which lists nothing: not second-guessed.
    let root = call(d, #"{"id":3,"method":"act","params":{"app":"Brave Browser","id":1,"action":"press"}}"#)
    try expect(root.contains(#""ok":true"#), root)
  }
}

func runScreenshotTests() {
  print("Photographing a window")
  func call(_ d: Dispatcher, _ json: String) -> String { d.handle(line: json) }

  test("screenshot returns the image, its encoding and size, and which window it is") {
    let b = FakeBackend()
    let d = Dispatcher(backend: b)
    let out = call(d, #"{"id":1,"method":"screenshot","params":{"app":"Brave Browser"}}"#)
    try expect(out.contains("9j") && out.contains("jpeg") && out.contains(#""image""#), out) // JSON escapes the slashes
    try expect(out.contains(#""width":1200"#) && out.contains(#""onSpace":true"#), out)
    try expect(!out.contains("note"), "a window on this Space needs no caveat: \(out)")
    try expectEqual(b.shotRequests.count, 1)
  }

  test("a window on another Space carries the hidden-content caveat, and the window id is passed through") {
    let b = FakeBackend()
    b.crossSpaceOn = true
    b.hideWindows = true
    let d = Dispatcher(backend: b)
    let out = call(d, #"{"id":1,"method":"screenshot","params":{"app":"Brave Browser","window":7}}"#)
    try expect(out.contains(#""onSpace":false"#) && out.contains("another Space"), out)
    try expectEqual(b.shotRequests.first?.windowId, 7)
  }

  test("a blank picture says so instead of pretending to be a picture") {
    let b = FakeBackend()
    b.blankShot = true
    let d = Dispatcher(backend: b)
    let out = call(d, #"{"id":1,"method":"screenshot","params":{"app":"Brave Browser"}}"#)
    try expect(out.contains(#""blank":true"#) && out.contains("BLANK"), out)
  }

  test("screenshot of an unknown app is the usual no_such_app") {
    let d = Dispatcher(backend: FakeBackend())
    let out = call(d, #"{"id":1,"method":"screenshot","params":{"app":"Nope"}}"#)
    try expect(out.contains("no_such_app"), out)
  }
}

func runUnresponsiveHintTests() {
  print("Saying why a press did nothing")
  func call(_ d: Dispatcher, _ json: String) -> String { d.handle(line: json) }

  test("an action that changed nothing carries the backend's explanation, when it has one") {
    let b = FakeBackend()
    b.unresponsiveWhy = "Brave is behind a fullscreen Space"
    let d = Dispatcher(backend: b)
    _ = call(d, #"{"id":1,"method":"tree","params":{"app":"Brave Browser"}}"#)
    let out = call(d, #"{"id":2,"method":"act","params":{"app":"Brave Browser","id":1,"action":"press"}}"#)
    try expect(out.contains("(no changes)") && out.contains("fullscreen Space"), out)
  }

  test("an action that changed something, or an app the backend cannot explain, gets no hint") {
    let quiet = FakeBackend()
    let d1 = Dispatcher(backend: quiet)
    _ = call(d1, #"{"id":1,"method":"tree","params":{"app":"Brave Browser"}}"#)
    let a = call(d1, #"{"id":2,"method":"act","params":{"app":"Brave Browser","id":1,"action":"press"}}"#)
    try expect(!a.contains("hint"), a)
    let changed = FakeBackend()
    changed.unresponsiveWhy = "would be wrong here"
    changed.snapshotsUntilChange = 1
    let d2 = Dispatcher(backend: changed)
    _ = call(d2, #"{"id":1,"method":"tree","params":{"app":"Brave Browser"}}"#)
    let b = call(d2, #"{"id":2,"method":"act","params":{"app":"Brave Browser","id":1,"action":"press"}}"#)
    try expect(!b.contains("hint"), "the app reacted, so nothing needs explaining: \(b)")
  }
}

func runRefindTests() {
  print("Re-finding an id the app rebuilt")
  func call(_ d: Dispatcher, _ json: String) -> String { d.handle(line: json) }
  // The fake's tree is fixed: 1 group, 2 the OK button, 3 the address field.
  let ok = 2

  // Measured twice on Maps and once in Codex's run of the same task: an app
  // rebuilds a control, the caller's id is refused, and a whole model round
  // trip goes on reading and trying again.

  test("an id the app rebuilt is matched to the same control and acted on") {
    let b = FakeBackend()
    let d = Dispatcher(backend: b)
    let first = call(d, #"{"id":1,"method":"tree","params":{"app":"Brave Browser"}}"#)
    try expect(first.contains("OK"), first)
    b.rebuildOK = true
    _ = call(d, #"{"id":2,"method":"tree","params":{"app":"Brave Browser","full":true}}"#) // the app rebuilt it
    let out = call(d, #"{"id":3,"method":"act","params":{"app":"Brave Browser","id":\#(ok),"action":"press"}}"#)
    try expect(out.contains(#""ok":true"#), out)
    try expect(out.contains(#""refoundId""#), "the caller must be told the new id: \(out)")
    guard let acted = b.acted.last else { try expect(false, "nothing was acted on"); return }
    try expect(acted.id != ok, "it acted on the new id, not the stale one: \(acted)")
  }

  test("two controls that match each other are refused rather than guessed between") {
    let b = FakeBackend()
    let d = Dispatcher(backend: b)
    _ = call(d, #"{"id":1,"method":"tree","params":{"app":"Brave Browser"}}"#)
    b.twoOKs = true
    _ = call(d, #"{"id":2,"method":"tree","params":{"app":"Brave Browser","full":true}}"#)
    let out = call(d, #"{"id":3,"method":"act","params":{"app":"Brave Browser","id":\#(ok),"action":"press"}}"#)
    try expect(out.contains("no_such_element"), "ambiguity must refuse rather than pick: \(out)")
    try expectEqual(b.acted.count, 0)
  }

  test("an id that was never handed out is refused as before") {
    let b = FakeBackend()
    let d = Dispatcher(backend: b)
    _ = call(d, #"{"id":1,"method":"tree","params":{"app":"Brave Browser"}}"#)
    let out = call(d, #"{"id":2,"method":"act","params":{"app":"Brave Browser","id":9999,"action":"press"}}"#)
    try expect(out.contains("no_such_element"), out)
  }
}

func runParkedRaiseTests() {
  print("Refusing a raise that cannot help")
  func call(_ d: Dispatcher, _ json: String) -> String { d.handle(line: json) }

  test("a parked window says so in the window line, before anything is tried") {
    let b = FakeBackend()
    b.parkedWindow = true
    let d = Dispatcher(backend: b)
    let out = call(d, #"{"id":1,"method":"windows","params":{"app":"Brave Browser"}}"#)
    try expect(out.contains("[parked]"), out)
    try expect(out.contains(#""parked":true"#), out)
  }

  // Six runs: a press does nothing because the window is parked, and the model
  // raises to fix it. The hint, the tool description and the skill all said
  // not to. So it is refused rather than described.

  test("while the window is parked, the first raise is refused and names the route that works") {
    let b = FakeBackend()
    b.parkedWindow = true
    let d = Dispatcher(backend: b)
    let out = call(d, #"{"id":1,"method":"raise","params":{"app":"Brave Browser"}}"#)
    try expect(out.contains("will not fix a press that did nothing"), out)
    try expect(out.contains("down") && out.contains("return"), "the refusal must name what to do instead: \(out)")
    try expectEqual(b.raised.count, 0, "nothing was raised")
  }

  test("asking a second time goes through, so intent is not blocked — only the reflex") {
    let b = FakeBackend()
    b.parkedWindow = true
    let d = Dispatcher(backend: b)
    _ = call(d, #"{"id":1,"method":"raise","params":{"app":"Brave Browser"}}"#) // refused
    let out = call(d, #"{"id":2,"method":"raise","params":{"app":"Brave Browser"}}"#)
    try expect(out.contains(#""ok":true"#), out)
    try expectEqual(b.raised.count, 1)
  }

  test("a window that is not parked is never touched") {
    let b = FakeBackend()
    let d = Dispatcher(backend: b)
    let out = call(d, #"{"id":1,"method":"raise","params":{"app":"Brave Browser"}}"#)
    try expect(out.contains(#""ok":true"#), out)
    try expectEqual(b.raised.count, 1)
  }

  // The rule this replaces armed on a dead action and disarmed on a successful
  // one, so the keyboard workaround — the very thing the refusal recommends —
  // switched the guard off at the moment it worked, and the reflex raise went
  // through five seconds later. Measured on 2026-09-06.

  test("succeeding at the keyboard route does not disarm the refusal") {
    let b = FakeBackend()
    b.parkedWindow = true
    b.snapshotsUntilChange = 1 // the next action changes the tree
    let d = Dispatcher(backend: b)
    _ = call(d, #"{"id":1,"method":"tree","params":{"app":"Brave Browser"}}"#)
    let worked = call(d, #"{"id":2,"method":"key","params":{"app":"Brave Browser","key":"return"}}"#)
    try expect(!worked.contains("(no changes)"), "the keyboard worked: \(worked)")
    let out = call(d, #"{"id":3,"method":"raise","params":{"app":"Brave Browser"}}"#)
    try expect(out.contains("will not fix"), "still parked, so the reflex is still refused: \(out)")
  }

  test("un-parking re-arms it, so the next episode gets its own refusal") {
    let b = FakeBackend()
    b.parkedWindow = true
    let d = Dispatcher(backend: b)
    _ = call(d, #"{"id":1,"method":"raise","params":{"app":"Brave Browser"}}"#) // refused, armed
    b.parkedWindow = false
    let allowed = call(d, #"{"id":2,"method":"raise","params":{"app":"Brave Browser"}}"#)
    try expect(allowed.contains(#""ok":true"#), allowed)
    b.parkedWindow = true
    let out = call(d, #"{"id":3,"method":"raise","params":{"app":"Brave Browser"}}"#)
    try expect(out.contains("will not fix"), "a new parked episode gets a fresh refusal: \(out)")
  }
}

func runRepeatTests() {
  print("Refusing the same action that already did nothing")
  func call(_ d: Dispatcher, _ json: String) -> String { d.handle(line: json) }
  let ok = 2 // the fake's OK button

  // One run pressed the same dead control twice in a row; another pressed one
  // control four different ways. Repeating an action that was accepted and
  // changed nothing cannot do anything.

  test("the same action again, after it changed nothing, is refused") {
    let b = FakeBackend()
    let d = Dispatcher(backend: b)
    _ = call(d, #"{"id":1,"method":"tree","params":{"app":"Brave Browser"}}"#)
    let first = call(d, #"{"id":2,"method":"act","params":{"app":"Brave Browser","id":\#(ok),"action":"press"}}"#)
    try expect(first.contains("(no changes)"), first)
    let second = call(d, #"{"id":3,"method":"act","params":{"app":"Brave Browser","id":\#(ok),"action":"press"}}"#)
    try expect(second.contains("already sent this exact action"), second)
    try expectEqual(b.acted.count, 1, "the repeat never reached the app")
  }

  test("the refusal does not say how to get around it") {
    let b = FakeBackend()
    b.parkedWindow = true
    let d = Dispatcher(backend: b)
    let raise = call(d, #"{"id":1,"method":"raise","params":{"app":"Brave Browser"}}"#)
    try expect(raise.contains("will not fix"), raise)
    try expect(!raise.lowercased().contains("ask for raise again"), "an earlier version advertised the second ask and the model took it: \(raise)")
    _ = call(d, #"{"id":2,"method":"tree","params":{"app":"Brave Browser"}}"#)
    _ = call(d, #"{"id":3,"method":"act","params":{"app":"Brave Browser","id":\#(ok),"action":"press"}}"#)
    let repeated = call(d, #"{"id":4,"method":"act","params":{"app":"Brave Browser","id":\#(ok),"action":"press"}}"#)
    try expect(!repeated.lowercased().contains("again and it will"), repeated)
  }

  test("a different action, or the same verb on a different element, goes through") {
    let b = FakeBackend()
    let d = Dispatcher(backend: b)
    _ = call(d, #"{"id":1,"method":"tree","params":{"app":"Brave Browser"}}"#)
    _ = call(d, #"{"id":2,"method":"act","params":{"app":"Brave Browser","id":\#(ok),"action":"press"}}"#) // nothing
    let elsewhere = call(d, #"{"id":3,"method":"setValue","params":{"app":"Brave Browser","id":3,"value":"x"}}"#)
    try expect(!elsewhere.contains("already sent"), "a different element and verb is not the same action: \(elsewhere)")
    let key = call(d, #"{"id":4,"method":"key","params":{"app":"Brave Browser","key":"return"}}"#)
    try expect(!key.contains("already sent"), "keys are exempt: \(key)")
  }

  test("an action that changed something may be repeated as often as it keeps working") {
    let b = FakeBackend()
    b.snapshotsUntilChange = 1 // every look differs from the baseline
    let d = Dispatcher(backend: b)
    _ = call(d, #"{"id":1,"method":"tree","params":{"app":"Brave Browser"}}"#)
    let first = call(d, #"{"id":2,"method":"act","params":{"app":"Brave Browser","id":\#(ok),"action":"press"}}"#)
    try expect(!first.contains("(no changes)"), first)
    let again = call(d, #"{"id":3,"method":"act","params":{"app":"Brave Browser","id":\#(ok),"action":"press"}}"#)
    try expect(!again.contains("already sent"), "pressing a tab back and forth is scope, not mechanism: \(again)")
  }

  // Keys are exempt on purpose. An app that does not expose its selection in
  // the tree makes every arrow key look like a no-op, and refusing the second
  // would break moving through a list — the path the parked-window advice
  // sends callers down.
  test("repeated keys are never blocked, even when the tree shows nothing") {
    let b = FakeBackend()
    let d = Dispatcher(backend: b)
    _ = call(d, #"{"id":1,"method":"tree","params":{"app":"Brave Browser"}}"#)
    for i in 2...5 {
      let out = call(d, #"{"id":\#(i),"method":"key","params":{"app":"Brave Browser","key":"down"}}"#)
      try expect(out.contains("(no changes)"), "the fake shows nothing for a key: \(out)")
      try expect(!out.contains("already sent"), "moving through a list must not be refused: \(out)")
    }
    try expectEqual(b.keys.count, 4)
  }

  test("asking a second time after the refusal goes through, quietly") {
    let b = FakeBackend()
    let d = Dispatcher(backend: b)
    _ = call(d, #"{"id":1,"method":"tree","params":{"app":"Brave Browser"}}"#)
    _ = call(d, #"{"id":2,"method":"act","params":{"app":"Brave Browser","id":\#(ok),"action":"press"}}"#)
    _ = call(d, #"{"id":3,"method":"act","params":{"app":"Brave Browser","id":\#(ok),"action":"press"}}"#) // refused
    let third = call(d, #"{"id":4,"method":"act","params":{"app":"Brave Browser","id":\#(ok),"action":"press"}}"#)
    try expect(third.contains(#""ok":true"#), third)
  }
}

func runKeyAndPointerTests() {
  print("Letters, modifiers, and pointer input")
  func call(_ d: Dispatcher, _ json: String) -> String { d.handle(line: json) }
  let canvas = 3 // the fake's text field; any element with a box will do

  // Figma's pen tool is `p` and has no element at all. Two separate agents
  // stalled on exactly that, and our own key verb accepted nine named keys.

  test("a single letter is a key, and a word is not") {
    try expect(Dispatcher.keyAllowed("p"))
    try expect(Dispatcher.keyAllowed("7"))
    try expect(Dispatcher.keyAllowed("return"))
    try expect(!Dispatcher.keyAllowed("pen"))
    try expect(!Dispatcher.keyAllowed(""))
    try expect(!Dispatcher.keyAllowed("P"), "the dispatcher lowercases before asking")
  }

  test("a letter reaches the backend, and an unknown key says what is allowed") {
    let b = FakeBackend()
    let d = Dispatcher(backend: b)
    let ok = call(d, #"{"id":1,"method":"key","params":{"app":"Brave Browser","key":"P"}}"#)
    try expect(ok.contains(#""ok":true"#), ok)
    try expectEqual(b.keys.last?.key, "p", "lowercased on the way through")
    let bad = call(d, #"{"id":2,"method":"key","params":{"app":"Brave Browser","key":"pen"}}"#)
    try expect(bad.contains("one letter") && bad.contains("bad_params"), bad)
  }

  test("modifiers are passed through, and an unknown one is refused by name") {
    let b = FakeBackend()
    let d = Dispatcher(backend: b)
    _ = call(d, #"{"id":1,"method":"key","params":{"app":"Brave Browser","key":"z","modifiers":["command","shift"]}}"#)
    try expectEqual(b.keyMods.last ?? [], ["command", "shift"])
    let bad = call(d, #"{"id":2,"method":"key","params":{"app":"Brave Browser","key":"z","modifiers":["meta"]}}"#)
    try expect(bad.contains("Unknown modifier") && bad.contains("meta"), bad)
    try expectEqual(b.keyMods.count, 1, "the bad call never reached the backend")
  }

  // The comparison run spent turns discovering a 2.8125 display scale factor
  // and drawing outside the frame. Fractions of a known box cannot do that.

  test("pointer takes fractions of the anchor's box and reports where they landed") {
    let b = FakeBackend()
    let d = Dispatcher(backend: b)
    _ = call(d, #"{"id":1,"method":"tree","params":{"app":"Brave Browser"}}"#)
    let out = call(d, #"{"id":2,"method":"pointer","params":{"app":"Brave Browser","id":\#(canvas),"path":[{"x":0,"y":0},{"x":0.5,"y":1}]}}"#)
    try expect(out.contains(#""ok":true"#), out)
    // The fake's box is 200x100, so 0.5,1 is 100,100.
    try expect(out.contains(#"{"x":0,"y":0}"#) && out.contains(#"{"x":100,"y":100}"#), "it must say where the fractions landed: \(out)")
    try expectEqual(b.pointerCalls.count, 1)
    try expectEqual(b.pointerCalls.first?.hold, false, "taps unless asked to hold")
  }

  test("hold is one drag, and modifiers ride along") {
    let b = FakeBackend()
    let d = Dispatcher(backend: b)
    _ = call(d, #"{"id":1,"method":"tree","params":{"app":"Brave Browser"}}"#)
    _ = call(d, #"{"id":2,"method":"pointer","params":{"app":"Brave Browser","id":\#(canvas),"path":[{"x":0.1,"y":0.1},{"x":0.9,"y":0.9}],"hold":true,"modifiers":["shift"]}}"#)
    try expectEqual(b.pointerCalls.first?.hold, true)
    try expectEqual(b.pointerCalls.first?.modifiers ?? [], ["shift"])
  }

  test("a point outside the box is refused, saying they are fractions") {
    let b = FakeBackend()
    let d = Dispatcher(backend: b)
    _ = call(d, #"{"id":1,"method":"tree","params":{"app":"Brave Browser"}}"#)
    for bad in [#"[{"x":430,"y":205}]"#, #"[{"x":0.5,"y":-0.1}]"#, #"[{"x":1.5,"y":0.5}]"#] {
      let out = call(d, #"{"id":2,"method":"pointer","params":{"app":"Brave Browser","id":\#(canvas),"path":\#(bad)}}"#)
      try expect(out.contains("FRACTIONS") && out.contains("bad_params"), "\(bad) -> \(out)")
    }
    try expectEqual(b.pointerCalls.count, 0, "nothing reached the app")
  }

  test("an empty path, a malformed point, and too many points are each refused") {
    let b = FakeBackend()
    let d = Dispatcher(backend: b)
    _ = call(d, #"{"id":1,"method":"tree","params":{"app":"Brave Browser"}}"#)
    let empty = call(d, #"{"id":2,"method":"pointer","params":{"app":"Brave Browser","id":\#(canvas),"path":[]}}"#)
    try expect(empty.contains("list of {x, y} points"), empty)
    let junk = call(d, #"{"id":3,"method":"pointer","params":{"app":"Brave Browser","id":\#(canvas),"path":[{"x":0.5}]}}"#)
    try expect(junk.contains("numeric x and y"), junk)
    let many = "[" + Array(repeating: #"{"x":0.5,"y":0.5}"#, count: Dispatcher.maxPathPoints + 1).joined(separator: ",") + "]"
    let over = call(d, #"{"id":4,"method":"pointer","params":{"app":"Brave Browser","id":\#(canvas),"path":\#(many)}}"#)
    try expect(over.contains("too many"), over)
    try expectEqual(b.pointerCalls.count, 0)
  }

  test("a stale anchor is re-found, and the backend's refusal reaches the caller") {
    let b = FakeBackend()
    b.pointerFails = "the window is parked by Stage Manager"
    let d = Dispatcher(backend: b)
    _ = call(d, #"{"id":1,"method":"tree","params":{"app":"Brave Browser"}}"#)
    let out = call(d, #"{"id":2,"method":"pointer","params":{"app":"Brave Browser","id":\#(canvas),"path":[{"x":0.5,"y":0.5}]}}"#)
    try expect(out.contains("parked by Stage Manager") && out.contains("action_failed"), out)
  }
}

func runFigmaCostTests() {
  print("What the Figma run cost")
  func call(_ d: Dispatcher, _ json: String) -> String { d.handle(line: json) }

  // command+shift+] is bring-to-front in every design tool. Refusing `]` sent
  // one run into several minutes of re-ordering layers by hand.
  test("shortcut punctuation is a key, and a two-character string still is not") {
    for k in ["]", "[", ",", ".", "/", "-", "=", ";", "'", "\\", "`"] {
      try expect(Dispatcher.keyAllowed(k), "\(k) carries a shortcut")
    }
    try expect(!Dispatcher.keyAllowed("]]"))
    try expect(!Dispatcher.keyAllowed("cmd"))
  }

  test("bring-to-front reaches the backend as one key with two modifiers") {
    let b = FakeBackend()
    let d = Dispatcher(backend: b)
    let out = call(d, #"{"id":1,"method":"key","params":{"app":"Brave Browser","key":"]","modifiers":["command","shift"]}}"#)
    try expect(out.contains(#""ok":true"#), out)
    try expectEqual(b.keys.last?.key, "]")
    try expectEqual(b.keyMods.last ?? [], ["command", "shift"])
  }

  // The transition rule was tuned on Maps, where a result list collapses
  // before a place card arrives. In Figma every selection change loses a
  // handful of rows and nothing more is coming, so a bare "fewer nodes" test
  // paid the long deadline 17 times in one task — 94 seconds of waiting.
  test("a tree that loses a few rows is tidier, not in transition, and returns at the floor") {
    let b = FakeBackend()
    b.shrunkUntilSnapshot = 1_000
    b.shrinkBy = 2 // a panel closing
    let d = Dispatcher(backend: b)
    _ = call(d, #"{"id":1,"method":"tree","params":{"app":"Brave Browser"}}"#)
    let started = Date()
    let out = call(d, #"{"id":2,"method":"act","params":{"app":"Brave Browser","id":2,"action":"press"}}"#)
    let elapsed = Date().timeIntervalSince(started)
    try expect(out.contains("removed"), out)
    try expect(elapsed < 2.0, "a small shrink must not buy the 3.5s transition budget (took \(elapsed)s)")
  }

  test("a tree that loses a whole list is still in transition and still waits") {
    let b = FakeBackend()
    b.shrunkUntilSnapshot = 1_000
    b.shrinkBy = 30 // a result list collapsing
    let d = Dispatcher(backend: b)
    _ = call(d, #"{"id":1,"method":"tree","params":{"app":"Brave Browser","full":true}}"#)
    let started = Date()
    _ = call(d, #"{"id":2,"method":"act","params":{"app":"Brave Browser","id":2,"action":"press"}}"#)
    let elapsed = Date().timeIntervalSince(started)
    try expect(elapsed >= 3.3, "a big shrink keeps the transition budget (took \(elapsed)s)")
  }
}

func runSettleFlagTests() {
  print("Skipping the wait mid-sequence")
  func call(_ d: Dispatcher, _ json: String) -> String { d.handle(line: json) }

  // A Figma icon built out of inspector fields: 372 actions and 253 seconds of
  // settle waiting, a fifth of the run. Every step of a batch paid for a
  // reaction nobody read, because a batch reports its NET effect at the end.

  test("settle:false does the action and returns at once") {
    let b = FakeBackend()
    let d = Dispatcher(backend: b)
    _ = call(d, #"{"id":1,"method":"tree","params":{"app":"Brave Browser"}}"#)
    let started = Date()
    let out = call(d, #"{"id":2,"method":"setValue","params":{"app":"Brave Browser","id":3,"value":"140","settle":false}}"#)
    let elapsed = Date().timeIntervalSince(started)
    try expect(out.contains(#""ok":true"#) && out.contains(#""settled":false"#), out)
    try expect(elapsed < 0.3, "no floor, no deadline (took \(elapsed)s)")
    try expectEqual(b.setValues.count, 1, "the action still happened")
  }

  test("the baseline is untouched, so a closing read reports the whole sequence") {
    let b = FakeBackend()
    let d = Dispatcher(backend: b)
    _ = call(d, #"{"id":1,"method":"tree","params":{"app":"Brave Browser"}}"#)
    b.snapshotsUntilChange = 1 // the tree gains a node from here on
    _ = call(d, #"{"id":2,"method":"act","params":{"app":"Brave Browser","id":2,"action":"press","settle":false}}"#)
    _ = call(d, #"{"id":3,"method":"act","params":{"app":"Brave Browser","id":2,"action":"press","settle":false}}"#)
    let closing = call(d, #"{"id":4,"method":"tree","params":{"app":"Brave Browser"}}"#)
    try expect(closing.contains("Result"), "the net effect shows up in the closing read: \(closing)")
  }

  test("a single action still settles, so the Maps case is untouched") {
    let b = FakeBackend()
    let d = Dispatcher(backend: b)
    _ = call(d, #"{"id":1,"method":"tree","params":{"app":"Brave Browser"}}"#)
    let started = Date()
    let out = call(d, #"{"id":2,"method":"setValue","params":{"app":"Brave Browser","id":3,"value":"x"}}"#)
    let elapsed = Date().timeIntervalSince(started)
    try expect(out.contains(#""waitedMs""#), out)
    try expect(elapsed >= 0.5, "the floor still applies without the flag (took \(elapsed)s)")
  }

  test("settle:false is not a way to dodge the guards") {
    let b = FakeBackend()
    let d = Dispatcher(backend: b)
    _ = call(d, #"{"id":1,"method":"tree","params":{"app":"Brave Browser"}}"#)
    let unlisted = call(d, #"{"id":2,"method":"act","params":{"app":"Brave Browser","id":2,"action":"show menu","settle":false}}"#)
    try expect(unlisted.contains("does not offer"), "the action list is still checked: \(unlisted)")
    let gone = call(d, #"{"id":3,"method":"act","params":{"app":"Brave Browser","id":9999,"action":"press","settle":false}}"#)
    try expect(gone.contains("no_such_element"), gone)
  }
}

// MARK: setValue read-back
//
// Measured in Figma: a width field holding "120" was given "180" and ended up
// reading "120180", and the run computed seventeen more coordinates on top of
// it. One attribute read after each write catches that. The rule has to be
// one-sided, though — the same app stores 160.3125 and DISPLAYS 160.31, so a
// guard demanding equality would refuse every fractional coordinate there is.

func runVerifyTests() {
  print("Reading a written value back")
  func call(_ d: Dispatcher, _ json: String) -> String { d.handle(line: json) }
  let read = #"{"id":1,"method":"tree","params":{"app":"Brave Browser"}}"#

  test("a write that reads back is accepted, and costs one value read") {
    let b = FakeBackend()
    let d = Dispatcher(backend: b)
    _ = call(d, read)
    let out = call(d, #"{"id":2,"method":"setValue","params":{"app":"Brave Browser","id":3,"value":"180","verify":true}}"#)
    try expect(out.contains(#""ok":true"#), out)
    try expectEqual(b.valueReads, [3], "exactly one read-back")
  }

  test("a field that ROUNDS the write is not a failure") {
    let b = FakeBackend()
    b.valueOverrides[3] = "160.31"
    let d = Dispatcher(backend: b)
    _ = call(d, read)
    let out = call(d, #"{"id":2,"method":"setValue","params":{"app":"Brave Browser","id":3,"value":"160.3125","verify":true}}"#)
    try expect(!out.contains(#""error""#), "rounding to 2dp must pass, or no fractional coordinate can be set: \(out)")
  }

  test("the appended value is refused, and the refusal names the fix") {
    let b = FakeBackend()
    b.valueOverrides[3] = "120180"
    let d = Dispatcher(backend: b)
    _ = call(d, read)
    let out = call(d, #"{"id":2,"method":"setValue","params":{"app":"Brave Browser","id":3,"value":"180","verify":true}}"#)
    try expect(out.contains(#""error""#), "expected a refusal: \(out)")
    try expect(out.contains("120180") && out.contains("180"), "say what is there and what was wanted: \(out)")
    try expect(out.contains("Nothing after this was run"), "a batch stopped here; say so: \(out)")
    try expect(out.contains("pointer"), "the remedy must CLICK the field first: \(out)")
    try expect(!out.contains("delete"), "never command+a then delete — outside a field that deletes every layer: \(out)")
  }

  test("a non-numeric field with the old text still glued on is refused") {
    let b = FakeBackend()
    b.valueOverrides[3] = "oldnew"
    let d = Dispatcher(backend: b)
    _ = call(d, read)
    let out = call(d, #"{"id":2,"method":"setValue","params":{"app":"Brave Browser","id":3,"value":"new","verify":true}}"#)
    try expect(out.contains(#""error""#), "the append signature does not need numbers: \(out)")
  }

  test("a field that normalises what it was given is left alone") {
    // A unit or symbol the field adds to what it stored. These END in extra
    // characters; the append bug leaves the old value in FRONT.
    for actual in ["100%", "100 px", "100pt", "Sep 7, 2026"] {
      let b = FakeBackend()
      b.valueOverrides[3] = actual
      let d = Dispatcher(backend: b)
      _ = call(d, read)
      let out = call(d, #"{"id":2,"method":"setValue","params":{"app":"Brave Browser","id":3,"value":"100","verify":true}}"#)
      try expect(!out.contains(#""error""#), "must not stop on a reformat it cannot judge (\(actual)): \(out)")
    }
  }

  test("an element exposing no value at all is left alone") {
    let b = FakeBackend()
    b.valueIsNil = true
    let d = Dispatcher(backend: b)
    _ = call(d, read)
    let out = call(d, #"{"id":2,"method":"setValue","params":{"app":"Brave Browser","id":3,"value":"100","verify":true}}"#)
    try expect(!out.contains(#""error""#), "no value to compare is not evidence of failure: \(out)")
  }

  test("a refused write leaves the baseline alone, so the next read still shows it") {
    let b = FakeBackend()
    b.valueOverrides[3] = "120180"
    let d = Dispatcher(backend: b)
    _ = call(d, read)
    _ = call(d, #"{"id":2,"method":"setValue","params":{"app":"Brave Browser","id":3,"value":"180","verify":true}}"#)
    let closing = call(d, #"{"id":3,"method":"tree","params":{"app":"Brave Browser"}}"#)
    try expect(!closing.contains(#""error""#), "the read after a refused write still works: \(closing)")
  }

  test("verify is OFF by default, because a stepper never reports the write") {
    // Figma's X/Y steppers ignore an AXValue write and keep reporting the old
    // value. Shipped default-on for a few hours and it refused writes that had
    // landed on other elements, which taught the caller to distrust the bridge.
    let b = FakeBackend()
    b.valueOverrides[3] = "120180"
    let d = Dispatcher(backend: b)
    _ = call(d, read)
    let out = call(d, #"{"id":2,"method":"setValue","params":{"app":"Brave Browser","id":3,"value":"180"}}"#)
    try expect(out.contains(#""ok":true"#), "no opt-in, no refusal: \(out)")
    try expect(b.valueReads.isEmpty, "and no read at all, got \(b.valueReads)")
  }

  test("verify:false skips the read entirely") {
    let b = FakeBackend()
    b.valueOverrides[3] = "120180"
    let d = Dispatcher(backend: b)
    _ = call(d, read)
    let out = call(d, #"{"id":2,"method":"setValue","params":{"app":"Brave Browser","id":3,"value":"180","verify":false}}"#)
    try expect(out.contains(#""ok":true"#), "opting out is allowed: \(out)")
    try expect(b.valueReads.isEmpty, "and costs nothing, got \(b.valueReads)")
  }
}

// MARK: which window a picture means
//
// Figma owns a 1470x33 strip beside its real 1470x923 document window.
// "Focused, else the first on this Space" picked the strip whenever Figma was
// not frontmost, and 33 pixels of chrome is one flat colour — so the picture
// came back blank and a 33-minute task was spent believing there was no visual
// channel at all.

func runWindowChoiceTests() {
  print("Choosing the window to photograph")
  func w(_ id: Int, _ title: String, _ width: Int, _ height: Int, focused: Bool = false, onSpace: Bool = true) -> WindowInfo {
    WindowInfo(id: id, title: title, x: 0, y: 0, width: width, height: height,
               minimized: false, focused: focused, onSpace: onSpace)
  }

  test("the document window wins over a chrome strip listed before it") {
    let picked = WindowInfo.likeliestDocument([w(1, "", 1470, 33), w(2, "Untitled", 1470, 923)])
    try expectEqual(picked.id, 2, "the 33-pixel strip is not what anyone means by Figma's window")
  }

  test("a focused window still wins, whatever its size") {
    let picked = WindowInfo.likeliestDocument([w(1, "", 1470, 33, focused: true), w(2, "Untitled", 1470, 923)])
    try expectEqual(picked.id, 1, "focus is the caller's own working window")
  }

  test("a visible window beats a bigger one on another Space") {
    let picked = WindowInfo.likeliestDocument([
      w(1, "huge elsewhere", 3840, 2160, onSpace: false),
      w(2, "here", 1200, 800, onSpace: true),
    ])
    try expectEqual(picked.id, 2, "a picture of something visible is worth more")
  }

  test("with everything off-Space the biggest is still chosen, not the first") {
    let picked = WindowInfo.likeliestDocument([
      w(1, "", 1470, 33, onSpace: false),
      w(2, "Untitled", 1470, 923, onSpace: false),
    ])
    try expectEqual(picked.id, 2, "off-Space windows photograph fine; pick the real one")
  }

  test("a single window is returned whatever it looks like") {
    try expectEqual(WindowInfo.likeliestDocument([w(7, "", 10, 10)]).id, 7)
  }
}

// MARK: typing a whole string, and click counts
//
// Codex's working recipe for a Figma stepper is four primitives: click the
// field, select all, type the number, commit. Ours needed twelve, because a
// key is one character — "-19.6875" alone is nine steps, so four fields did
// not fit a batch at all.

func runTypeTests() {
  print("Typing text and counting clicks")
  func call(_ d: Dispatcher, _ json: String) -> String { d.handle(line: json) }
  let read = #"{"id":1,"method":"tree","params":{"app":"Brave Browser"}}"#

  test("one call types the whole string, punctuation and sign included") {
    let b = FakeBackend()
    let d = Dispatcher(backend: b)
    _ = call(d, read)
    let out = call(d, #"{"id":2,"method":"type","params":{"app":"Brave Browser","text":"-19.6875"}}"#)
    try expect(out.contains(#""ok":true"#), out)
    try expectEqual(b.typed.count, 1, "one call, not nine")
    try expectEqual(b.typed[0].text, "-19.6875")
    try expect(b.typed[0].focusId == nil, "without id it lands wherever focus is")
  }

  test("an id focuses the field first") {
    let b = FakeBackend()
    let d = Dispatcher(backend: b)
    _ = call(d, read)
    _ = call(d, #"{"id":2,"method":"type","params":{"app":"Brave Browser","text":"460","id":3}}"#)
    try expectEqual(b.typed[0].focusId, 3)
  }

  test("empty text and an essay are both refused, by reason") {
    let b = FakeBackend()
    let d = Dispatcher(backend: b)
    _ = call(d, read)
    try expect(call(d, #"{"id":2,"method":"type","params":{"app":"Brave Browser","text":""}}"#).contains("nothing to type"))
    let long = String(repeating: "x", count: Dispatcher.maxTypeLength + 1)
    try expect(call(d, "{\"id\":3,\"method\":\"type\",\"params\":{\"app\":\"Brave Browser\",\"text\":\"\(long)\"}}").contains("at most"))
    try expect(b.typed.isEmpty, "neither reached the backend")
  }

  test("a pointer click defaults to one click and takes a double") {
    let b = FakeBackend()
    let d = Dispatcher(backend: b)
    _ = call(d, read)
    _ = call(d, #"{"id":2,"method":"pointer","params":{"app":"Brave Browser","id":3,"path":[{"x":0.5,"y":0.5}]}}"#)
    _ = call(d, #"{"id":3,"method":"pointer","params":{"app":"Brave Browser","id":3,"path":[{"x":0.5,"y":0.5}],"clicks":2}}"#)
    try expectEqual(b.clickCounts, [1, 2], "the count reaches the backend")
  }

  test("an absent path means the middle of the element") {
    let b = FakeBackend()
    let d = Dispatcher(backend: b)
    _ = call(d, read)
    let out = call(d, #"{"id":2,"method":"pointer","params":{"app":"Brave Browser","id":3}}"#)
    try expect(out.contains(#""ok":true"#), "clicking a field should not need x and y spelled out: \(out)")
    try expectEqual(b.pointerCalls.count, 1)
    try expectEqual(b.pointerCalls[0].path.count, 1)
    try expect(b.pointerCalls[0].path[0].x == 0.5 && b.pointerCalls[0].path[0].y == 0.5, "centre")
  }

  test("a silly click count is refused rather than hammering a control") {
    let b = FakeBackend()
    let d = Dispatcher(backend: b)
    _ = call(d, read)
    let out = call(d, #"{"id":2,"method":"pointer","params":{"app":"Brave Browser","id":3,"clicks":40}}"#)
    try expect(out.contains("clicks must be"), out)
    try expect(b.pointerCalls.isEmpty, "nothing was clicked")
  }

  test("type is listed as a method and refuses an unknown app like the rest") {
    let b = FakeBackend()
    let d = Dispatcher(backend: b)
    let out = call(d, #"{"id":1,"method":"type","params":{"app":"Nope","text":"x"}}"#)
    try expect(out.contains("no_such_app"), out)
    try expect(call(d, #"{"id":2,"method":"nonsense","params":{}}"#).contains("type"), "the method list names it")
  }
}

func runWindowCountTests() {
  print("Counting windows a person could switch to")

  // Measured on a freshly launched Maps with ONE window: it owns six layer-0
  // windows. Counting all of them reported "6 windows on another Space", and
  // the read-side recovery raised the app eight times in one task on the
  // strength of that number.

  test("a real window counts") {
    try expect(isUserWindow(width: 1024, height: 768, layer: 0, onscreen: false),
      "Maps' actual 1024x768 window must count")
    try expect(isUserWindow(width: 500, height: 500, layer: 0, onscreen: false),
      "a small panel still counts — over-counting by one only wastes a raise")
  }

  test("the full-width strips a Catalyst app owns do not count") {
    // Four of these, exactly: 3840x30.
    try expect(!isUserWindow(width: 3840, height: 30, layer: 0, onscreen: false),
      "a 30px strip spanning the display is not a window anyone switches to")
    try expect(!isUserWindow(width: 0, height: 0, layer: 0, onscreen: false), "zero-sized")
    try expect(!isUserWindow(width: 60, height: 60, layer: 0, onscreen: false), "tiny surfaces")
  }

  test("a window already on this Space is not counted as elsewhere") {
    try expect(!isUserWindow(width: 1024, height: 768, layer: 0, onscreen: true),
      "onscreen means it is HERE, and the caller reads it from the tree instead")
  }

  test("panels, menus and shadows above the window layer do not count") {
    try expect(!isUserWindow(width: 1024, height: 768, layer: 3, onscreen: false),
      "only layer 0 holds ordinary windows")
    try expect(!isUserWindow(width: 1024, height: 768, layer: 25, onscreen: false), "status items")
  }

  test("the measured Maps window set now counts 2, not 6") {
    let measured: [(Double, Double)] = [(500, 500), (1024, 768), (3840, 30), (3840, 30), (3840, 30), (3840, 30)]
    let n = measured.filter { isUserWindow(width: $0.0, height: $0.1, layer: 0, onscreen: false) }.count
    try expectEqual(n, 2, "the four strips must fall out")
  }
}
