import Foundation

/// One request line in, one response line out. Holds the last snapshot per
/// app so `tree` can answer with a diff and `act` can refuse ids the model
/// never saw. Foundation is imported here for JSONSerialization only; the
/// rest of AXModel stays framework-free.
public final class Dispatcher {
  public static let methods = ["hello", "apps", "windows", "tree", "find", "act", "setValue", "key", "raise", "icon", "launch", "scroll", "screenshot"]
  public static let keys = ["return", "tab", "escape", "space", "delete", "up", "down", "left", "right"]

  private let backend: Backend
  private var last: [String: Snapshot] = [:]
  /// See remember(_:_:) — id -> what that id described, per app.
  private var idMemory: [String: [Int: Attributes]] = [:]
  /// Apps whose last action was accepted, changed nothing, and had a reason:
  /// the window is parked. The next raise for such an app is refused once —
  /// see the "raise" case.
  private var deadOnParked: Set<String> = []

  public init(backend: Backend) { self.backend = backend }

  public func handle(line: String) -> String {
    guard let data = line.data(using: .utf8),
          let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let method = obj["method"] as? String else {
      return encode(["error": ["code": "bad_request", "message": "Each line must be a JSON object with a \"method\"."]])
    }
    let id: Any = obj["id"] ?? NSNull()
    let params = obj["params"] as? [String: Any] ?? [:]
    do {
      return encode(["id": id, "result": try dispatch(method, params)])
    } catch let e as BridgeError {
      return encode(["id": id, "error": ["code": e.code, "message": e.message]])
    } catch {
      return encode(["id": id, "error": ["code": "internal", "message": "\(error)"]])
    }
  }

  private func dispatch(_ method: String, _ p: [String: Any]) throws -> Any {
    guard Self.methods.contains(method) else { throw BridgeError.unknownMethod(method) }
    switch method {
    case "hello":
      return ["name": "unbiased-ax", "protocolVersion": protocolVersion, "trusted": backend.isTrusted(), "crossSpace": backend.crossSpace()]
    case "apps":
      return ["apps": backend.apps().map(asDict)]
    default: break
    }
    guard backend.isTrusted() else { throw BridgeError.notTrusted }
    let app = try string(p, "app")
    let geometry = (p["geometry"] as? Bool) ?? false
    switch method {
    case "icon":
      return ["png": try backend.appIcon(app: app).base64EncodedString()]
    case "windows":
      let wins = try backend.windows(app: app)
      var out: [String: Any] = ["windows": wins.map(asDict), "text": wins.map(\.line).joined(separator: "\n")]
      try annotateSpaces(&out, app: app, windowsHere: { wins.count })
      return out
    case "tree":
      let snap = try backend.snapshot(app: app, options: options(p))
      defer { last[app] = snap; remember(app, snap) }
      var out: [String: Any] = ["count": snap.nodes.count, "truncated": snap.truncated]
      if let prev = last[app], !((p["full"] as? Bool) ?? false) {
        out["diff"] = Differ.render(from: prev, to: snap, geometry: geometry)
      } else {
        out["tree"] = Formatter.render(snap, geometry: geometry)
      }
      // A read is where the model actually meets this problem, and until now
      // it was the one place we did not say so: an app whose windows are all
      // on another Space returns the menu bar and nothing else, with no
      // explanation. A model given eight bare elements concludes the tool is
      // broken and leaves for the shell. `windows` carried this hint from the
      // start; `tree` — the read the model actually calls — never did.
      try annotateSpaces(&out, app: app, windowsHere: { try self.backend.windows(app: app).count })
      return out
    case "find":
      let snap = try backend.snapshot(app: app, options: options(p))
      last[app] = snap; remember(app, snap)
      let role = p["role"] as? String
      let needle = (p["title"] as? String)?.lowercased()
      let hits = snap.nodes.filter { n in
        (role == nil || n.attributes.role == role!) &&
        (needle == nil || (n.attributes.title ?? "").lowercased().contains(needle!) || (n.attributes.value ?? "").lowercased().contains(needle!))
      }
      var out: [String: Any] = ["matches": hits.map { Formatter.line($0, geometry: geometry) }, "count": hits.count]
      try annotateSpaces(&out, app: app, windowsHere: { try self.backend.windows(app: app).count })
      return out
    case "act":
      let asked = try int(p, "id"); let action = try string(p, "action")
      let id = try resolveId(app, asked)
      try offers(app, id, action)
      try backend.perform(app: app, id: id, action: action, keepFront: (p["keepFront"] as? Bool) ?? false)
      return try afterAction(app, p, refound: asked == id ? nil : (asked, id))
    case "setValue":
      let asked = try int(p, "id"); let value = try string(p, "value")
      let id = try resolveId(app, asked)
      try backend.setValue(app: app, id: id, value: value, keepFront: (p["keepFront"] as? Bool) ?? false)
      return try afterAction(app, p, refound: asked == id ? nil : (asked, id))
    case "key":
      let key = try string(p, "key").lowercased()
      guard Self.keys.contains(key) else { throw BridgeError.badParams("Unknown key \"\(key)\". Keys: \(Self.keys.joined(separator: ", ")).") }
      let asked = p["id"] as? Int
      let focusId = try asked.map { try resolveId(app, $0) }
      try backend.pressKey(app: app, key: key, focusId: focusId)
      return try afterAction(app, p, refound: asked == focusId ? nil : (asked!, focusId!))
    case "raise":
      // Measured three runs in a row: a press does nothing because the window
      // is parked, and the caller raises to fix it. That cannot work. Raising
      // un-parks the window only while the app is in front, and it re-parks
      // the moment focus moves on, so the user loses their screen and the next
      // press is dead again. Guidance did not stop it — the hint, this tool's
      // own description and the bundled skill all said so, and it raised
      // anyway — so the reflex is refused rather than described.
      //
      // Once, and only once. A caller that means it, or a user who asked to
      // SEE the app, gets it on the second ask. This blocks the reflex, not
      // the intent.
      if deadOnParked.remove(app) != nil {
        throw BridgeError.actionFailed("Raising \(app) will not fix a press that did nothing: the window re-parks as soon as focus moves on, so this costs the user their screen and changes nothing. Do the keyboard route instead — key \"down\", then key \"return\" — or use a menu bar item. Ask for raise again if you genuinely need the app in front, and it will go through.")
      }
      try backend.raise(app: app, windowId: p["window"] as? Int)
      return try afterAction(app, p)
    case "launch":
      let timeout = (p["timeout"] as? Double) ?? 15
      let alreadyRunning = backend.apps().contains { $0.name == app || $0.bundleId == app }
      guard try backend.launch(app: app, timeout: timeout) else {
        throw BridgeError.launchFailed("Could not launch \"\(app)\". Check the name against the user's installed apps; it is not something this tool can create.")
      }
      // Return the tree, not just ok: the model's next move is always to read,
      // and a launched app is the one case where waiting for it to be readable
      // is our job rather than something to make the model poll for.
      let snap = try backend.snapshot(app: app, options: options(p))
      last[app] = snap; remember(app, snap)
      var out: [String: Any] = [
        "ok": true,
        "alreadyRunning": alreadyRunning,
        "tree": Formatter.render(snap, geometry: false),
        "count": snap.nodes.count,
      ]
      try annotateSpaces(&out, app: app, windowsHere: { try self.backend.windows(app: app).count })
      return out
    case "screenshot":
      let shot = try backend.screenshot(app: app, windowId: p["window"] as? Int)
      var out: [String: Any] = ["image": shot.image.base64EncodedString(), "mime": shot.mime, "width": shot.width, "height": shot.height,
                                "window": shot.windowId, "onSpace": shot.onSpace, "blank": shot.blank]
      if shot.blank {
        out["note"] = "The picture is BLANK: one colour, nothing drawn. Either this window has never been on screen since the app launched, or Screen Recording is not granted for the app. Do not raise the app to see it; the tree carries the text."
      } else if !shot.onSpace {
        // Measured: told the tiles "may be blank", the model raised the app to
        // see them. Say what the blank means and what not to do about it.
        out["note"] = "This window is on another Space. Controls and text are in the picture; content the app draws only while on screen (map tiles, video, some web views) is blank. That is the picture's limit, not a reason to raise the app: the tree already carries the text, and a task that truly needs the blank part should be reported to the user, not solved by taking their screen."
      }
      return out
    case "scroll":
      let id = try resolveId(app, try int(p, "id"))
      let dy = (p["dy"] as? Int) ?? 0
      let dx = (p["dx"] as? Int) ?? 0
      guard dx != 0 || dy != 0 else { throw BridgeError.badParams("Pass a non-zero dx or dy. Negative dy scrolls down, positive up.") }
      try backend.scroll(app: app, id: id, dx: dx, dy: dy)
      return try afterAction(app, p)
    default:
      throw BridgeError.unknownMethod(method)
    }
  }

  /// Off-Space windows, and what to do about them. Without the remote-token
  /// path AXWindows lists only the current Space, so "no windows" and "windows
  /// elsewhere" look identical in a tree; the hint is the only thing that tells
  /// them apart, and its advice differs by whether anything readable is HERE:
  /// with a window on this Space the model raised for no reason and took the
  /// user's screen; with none, no amount of reading finds the window — a model
  /// spent six minutes proving that, and another lost the task to a shell.
  /// With the remote-token path proved, every window the scan reached is in
  /// the tree and one hint is left: the window server lists windows and the
  /// tree has none, so the scan has not reached them yet — read again.
  /// `windowsHere` is a closure because it is only needed when something is
  /// off-Space, and computing it is a window scan.
  private func annotateSpaces(_ out: inout [String: Any], app: String, windowsHere: () throws -> Int) throws {
    let off = try backend.offscreenWindows(app: app)
    out["offscreen"] = off
    guard off > 0 else { return }
    if backend.crossSpace() {
      // Every window the scan reached is already in the tree, so there is only
      // one thing left worth saying: the window server lists windows and the
      // tree has none. The scan has not reached them yet — never shown, or the
      // first look aborted — and reading again is the answer, not raising.
      if try windowsHere() == 0 {
        out["hint"] = "The window server lists \(off) window(s) for this app that could not be read yet. Read again; if it stays empty, the app has no window to work in. Do not raise."
      }
      return
    }
    if try windowsHere() == 0 {
      out["hint"] = "This app's \(off) window(s) are all on another Space or hidden. They are NOT in the tree and cannot be read or acted on from here: call raise for this app first, then read again."
    } else {
      out["hint"] = "\(off) further window(s) are on another Space or hidden. The window(s) here are readable — work with those; do not raise."
    }
  }

  /// Re-snapshot and return the diff: the model sees what its action did
  /// without spending a second round-trip to look.
  private func afterAction(_ app: String, _ p: [String: Any], refound: (from: Int, to: Int)? = nil) throws -> Any {
    // Snapshot AFTER the app has had a chance to react, not the instant the
    // action returns. Measured: pressing return in Maps' search field produced
    // "(no changes)" while the three results were on their way, and the model
    // — told nothing had happened — read again to find out. Seven redundant
    // reads in one task, each a whole round trip, because this returned too
    // early.
    //
    // Polled rather than slept: an action whose effect is already visible pays
    // nothing, and only one that truly changes nothing waits out the deadline.
    let opts = options(p)
    var snap = try backend.snapshot(app: app, options: opts)
    // How long the action waited for the app, so a caller's diagnostics can
    // say where a slow task spent its time.
    var waitedMs = 0
    if let prev = last[app] {
      let started = Date()
      var stableLooks = 0
      // Settle policy, set from measurement rather than taste. Typing into
      // Maps' search field and pressing return:
      //   ~120ms  the FIELD updates — the echo of our own keystroke
      //   ~477ms  the three results actually appear
      // Returning at the first change reported only the echo. Returning at the
      // first quiescence returned at 305ms, in the stable gap between the two,
      // and reported the echo again. So: require both a quiet tree AND a floor
      // under how early we are willing to call it.
      //
      // The cost of being wrong here is a whole model round trip — seconds —
      // which is precisely what the model spent seven of in one task, reading
      // again because the action said nothing had happened.
      //
      // Second measurement, a day later: pressing a Maps search result. The
      // result LIST collapsed within ~300ms and the tree went quiet; the place
      // card that replaces it rendered ~2.5s after the press. Quiet-and-past-
      // the-floor returned the collapse alone, and the model — shown a tree
      // that had only lost things — read again, pressed again, and toggled a
      // setting while it was at it. Three turns. So a tree that has only
      // SHRUNK since the action is treated as in transition, not settled: it
      // gets a longer deadline, and returns early only once something has
      // arrived to replace what left. An action whose honest final state is a
      // smaller tree (closing a menu, dismissing a dialog) pays the longer
      // wait — seconds, against the model turns the alternative costs.
      while true {
        let elapsed = Date().timeIntervalSince(started)
        let reacted = Differ.changed(from: prev, to: snap)
        let shrank = snap.nodes.count < prev.nodes.count
        if elapsed >= (shrank ? Self.settleDeadlineShrunk : Self.settleDeadline) { break }
        if reacted && !shrank && stableLooks >= 1 && elapsed >= Self.settleFloor { break }
        Thread.sleep(forTimeInterval: Self.settleStep)
        let again = try backend.snapshot(app: app, options: opts)
        stableLooks = Differ.changed(from: snap, to: again) ? 0 : stableLooks + 1
        snap = again
      }
      waitedMs = Int(Date().timeIntervalSince(started) * 1000)
    }
    let diff = last[app].map { Differ.render(from: $0, to: snap, geometry: false) } ?? Formatter.render(snap, geometry: false)
    last[app] = snap; remember(app, snap)
    var out: [String: Any] = ["ok": true, "diff": diff, "waitedMs": waitedMs]
    if let refound {
      // Say it plainly: the caller's number is stale from here on, and the
      // reason its next read looks renumbered is this, not a phantom.
      out["refoundId"] = refound.to
      out["note"] = "Element \(refound.from) was gone; the same control is now \(refound.to) and that is what was acted on. Use \(refound.to) from here."
    }
    // Nothing moved: if the backend knows why this app ignores presses, say so
    // now, before the model retries the same control four different ways.
    if diff == "(no changes)", let why = backend.unresponsiveHint(app: app) {
      out["hint"] = why
      deadOnParked.insert(app)
    } else if diff != "(no changes)" {
      deadOnParked.remove(app)
    }
    return out
  }

  /// How long to wait for an app to react before reporting no change, and how
  /// often to look. Chosen from what Maps needs: results and a route sheet
  /// arrive within a few hundred ms, a Transit tab can take seconds — but a
  /// tab that slow is worth an explicit wait from the caller rather than
  /// making every no-op action pay for it here.
  /// Upper bound on the wait. An action that genuinely changes nothing pays
  /// this in full, which is the honest cost of not being able to tell a no-op
  /// from an app that is still thinking.
  static let settleDeadline = 1.5
  /// Upper bound while the tree has only shrunk since the action: what left
  /// is likely making room for what has not arrived yet. Maps' place card
  /// landed ~2.5s after the result list collapsed.
  static let settleDeadlineShrunk = 3.5
  /// Do not declare an app settled before this, once it has reacted at all.
  /// Maps' results land at ~477ms; anything under that reports the keystroke
  /// echo and calls it a result.
  static let settleFloor = 0.6
  static let settleStep = 0.1

  /// The id the caller means, in terms of the CURRENT snapshot.
  ///
  /// An id is the identity of one element, so an app that tears a control down
  /// and builds it again gives the same-looking control a new id. The caller is
  /// then holding a number for something that no longer exists, and every such
  /// refusal costs a whole model round trip to re-read and try again. Measured
  /// on Maps: twice in one task, and once in Codex's own run of it.
  ///
  /// So when the id is gone, look at what it USED to be and see whether the
  /// snapshot has exactly one element that matches. One match is the same
  /// control after a rebuild. Zero or several is a genuine miss, and refusing
  /// is right: acting on a guess is worse than another read.
  private func resolveId(_ app: String, _ id: Int) throws -> Int {
    guard let snap = last[app] else { throw BridgeError.noSuchElement(id) }
    if snap.nodes.contains(where: { $0.id == id }) { return id }
    guard let want = idMemory[app]?[id], Self.identifiable(want) else { throw BridgeError.noSuchElement(id) }
    let matches = snap.nodes.filter { Self.sameControl($0.attributes, want) }
    guard matches.count == 1 else { throw BridgeError.noSuchElement(id) }
    return matches[0].id
  }

  /// Only a control with something to match on can be re-found. A bare
  /// "button" with no title and no value describes half a toolbar.
  private static func identifiable(_ a: Attributes) -> Bool {
    !(a.title ?? "").isEmpty || !(a.value ?? "").isEmpty
  }

  /// Same role, same title, same value. Deliberately not position: a control
  /// that moved is exactly the case this exists for.
  private static func sameControl(_ a: Attributes, _ b: Attributes) -> Bool {
    a.role == b.role && (a.title ?? "") == (b.title ?? "") && (a.value ?? "") == (b.value ?? "")
  }

  /// What each id looked like, across every snapshot of an app, so a refused
  /// id can be matched against the control it named. Capped: ids only ever
  /// increase, so dropping the lowest drops the oldest.
  private func remember(_ app: String, _ snap: Snapshot) {
    var mem = idMemory[app] ?? [:]
    for n in snap.nodes where Self.identifiable(n.attributes) { mem[n.id] = n.attributes }
    if mem.count > Self.idMemoryCap {
      for id in mem.keys.sorted().prefix(mem.count - Self.idMemoryCap) { mem.removeValue(forKey: id) }
    }
    idMemory[app] = mem
  }
  static let idMemoryCap = 6_000

  /// An action the element did not list is refused before it is tried. Run 4
  /// of the Maps task: the model pressed a tab button whose line showed no
  /// actions at all; AXPress returned success and nothing happened, and the
  /// model spent four turns finding that out. Only a non-empty list is
  /// trusted here — an empty one may mean the actions were never fetched.
  private func offers(_ app: String, _ id: Int, _ action: String) throws {
    guard let node = last[app]?.nodes.first(where: { $0.id == id }), !node.attributes.actions.isEmpty, !node.attributes.actions.contains(action) else { return }
    throw BridgeError.actionFailed("Element \(id) does not offer \"\(action)\"; it offers {\(node.attributes.actions.joined(separator: ","))}. Use one of those, or a different path: the keyboard, or a menu bar command.")
  }

  private func options(_ p: [String: Any]) -> SnapshotOptions {
    var o = SnapshotOptions()
    if let d = p["depth"] as? Int { o.maxDepth = d }
    if let m = p["maxElements"] as? Int { o.maxElements = m }
    if let i = p["interactive"] as? Bool { o.interactiveOnly = i }
    if let w = p["web"] as? Bool { o.webContent = w }
    return o
  }

  private func string(_ p: [String: Any], _ k: String) throws -> String {
    guard let v = p[k] as? String, !v.isEmpty else { throw BridgeError.badParams("Missing required string param \"\(k)\".") }
    return v
  }
  private func int(_ p: [String: Any], _ k: String) throws -> Int {
    guard let v = p[k] as? Int else { throw BridgeError.badParams("Missing required integer param \"\(k)\".") }
    return v
  }
  private func asDict<T: Encodable>(_ v: T) -> Any {
    (try? JSONSerialization.jsonObject(with: JSONEncoder().encode(v))) ?? [:]
  }
  private func encode(_ obj: [String: Any]) -> String {
    guard let d = try? JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys]) else {
      return "{\"error\":{\"code\":\"internal\",\"message\":\"encode failed\"}}"
    }
    return String(decoding: d, as: UTF8.self)
  }
}
