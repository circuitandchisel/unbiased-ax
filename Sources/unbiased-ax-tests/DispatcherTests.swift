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
  var keys: [(app: String, key: String)] = []
  var registries: [String: IdRegistry] = [:]
  let tree = group("w", [button("w/ok", "OK"),
                         FakeNode("w/url", Attributes(role: "text field", title: "Address", value: "a.com", width: 300, height: 20))],
                   title: "Win")

  func isTrusted() -> Bool { trusted }
  func apps() -> [AppInfo] {
    [AppInfo(pid: 10, name: "Brave Browser", bundleId: "com.brave.Browser", frontmost: true),
     AppInfo(pid: 11, name: "Finder", bundleId: "com.apple.finder", frontmost: false)]
  }
  func windows(app: String) throws -> [WindowInfo] {
    guard app == "Brave Browser" else { throw BridgeError.noSuchApp(app) }
    return hideWindows ? [] : [WindowInfo(id: 1, title: "YouTube - Brave", x: 0, y: 0, width: 1200, height: 800, minimized: false, focused: true)]
  }
  func snapshot(app: String, options: SnapshotOptions) throws -> Snapshot {
    guard app == "Brave Browser" else { throw BridgeError.noSuchApp(app) }
    lastOptions = options
    var reg = registries[app] ?? IdRegistry()
    defer { registries[app] = reg }
    return Snapshot.build(root: tree, source: FakeSource(), registry: &reg, options: options)
  }
  func offscreenWindows(app: String) throws -> Int { offscreen }
  var iconPNG: Data? = Data([0x89, 0x50, 0x4E, 0x47])
  func appIcon(app: String) throws -> Data {
    guard let d = iconPNG else { throw BridgeError.noSuchApp(app) }
    return d
  }
  var focused: [(app: String, id: Int)] = []
  func pressKey(app: String, key: String, focusId: Int?) throws {
    if let id = focusId { focused.append((app, id)) }
    keys.append((app, key))
  }
  var keepFrontSeen: [Bool] = []
  func perform(app: String, id: Int, action: String, keepFront: Bool) throws {
    keepFrontSeen.append(keepFront); acted.append((app, id, action))
  }
  func setValue(app: String, id: Int, value: String, keepFront: Bool) throws {
    keepFrontSeen.append(keepFront); setValues.append((app, id, value))
  }
  func raise(app: String, windowId: Int?) throws {}
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
  test("keepFront rides with act and setValue, and defaults on") {
    // Measured, reported by the user: the screen switched to the browser on
    // EVERY action, not just the raise. Pressing an element and setting a
    // value both pull their app forward, so the bridge has to put back
    // whatever was in front — otherwise a ten-action task is ten switches.
    let b = FakeBackend(); let d = Dispatcher(backend: b)
    _ = call(d, #"{"id":50,"method":"tree","params":{"app":"Brave Browser"}}"#)
    _ = call(d, #"{"id":51,"method":"act","params":{"app":"Brave Browser","id":2,"action":"press"}}"#)
    try expectEqual(b.keepFrontSeen.last, true, "default is to keep the user where they are")
    _ = call(d, #"{"id":52,"method":"setValue","params":{"app":"Brave Browser","id":3,"value":"x","keepFront":false}}"#)
    try expectEqual(b.keepFrontSeen.last, false, "a caller can ask for the app to stay in front")
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
