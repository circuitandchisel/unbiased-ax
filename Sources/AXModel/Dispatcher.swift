import Foundation

/// One request line in, one response line out. Holds the last snapshot per
/// app so `tree` can answer with a diff and `act` can refuse ids the model
/// never saw. Foundation is imported here for JSONSerialization only; the
/// rest of AXModel stays framework-free.
public final class Dispatcher {
  public static let methods = ["hello", "apps", "windows", "tree", "find", "act", "setValue", "key", "raise", "icon", "launch", "scroll", "screenshot", "pointer", "type", "values"]
  public static let keys = ["return", "tab", "escape", "space", "delete", "up", "down", "left", "right"]
  public static let modifiers = ["command", "shift", "option", "control"]
  /// How many points one pointer call may carry. A logo outline is a dozen; a
  /// thousand would be a way to hold the desktop tools for a minute.
  public static let maxPathPoints = 60
  /// How many ids one `values` call may read back: every field on a shape,
  /// with room to spare, and not a way to walk the tree one attribute at a time.
  public static let maxValueIds = 40
  /// 2 is a double click. Past 3 nothing in a desktop app means anything.
  public static let maxClicks = 3
  /// A field value, a search phrase, a short label — not a document.
  public static let maxTypeLength = 500

  /// The punctuation that carries a shortcut. Figma's bring-to-front is
  /// command+shift+], and refusing `]` sent one run into several minutes of
  /// re-ordering layers by hand.
  public static let punctuationKeys = "[]-=,./;'\\`"

  /// A named key, or one character: a letter, a digit, or shortcut
  /// punctuation. Letters matter because a design tool puts its tools behind
  /// one-character shortcuts and exposes no element for them at all: Figma's
  /// pen is `p` and nothing else, which is where two separate agents stalled.
  public static func keyAllowed(_ key: String) -> Bool {
    if keys.contains(key) { return true }
    guard key.count == 1, let c = key.unicodeScalars.first else { return false }
    if (c >= "a" && c <= "z") || (c >= "0" && c <= "9") { return true }
    return punctuationKeys.unicodeScalars.contains(c)
  }

  private let backend: Backend
  /// One diff baseline per (app, filter). A filter flip diffs against that
  /// filter's own last read; only a filter never read before gets a full tree.
  /// Measured 2026-09-08 on the Figma logo run: 28 web/interactive flips
  /// between consecutive reads, each forcing the app to ask for the whole
  /// tree (~9KB), and the two compactions that followed cost nine minutes.
  private var baselines: [String: [String: Snapshot]] = [:]
  /// The most recent snapshot of each app under any filter: what a stale id
  /// is re-found against, and where an element's action list is looked up.
  private var latest: [String: Snapshot] = [:]
  /// See remember(_:_:) — id -> what that id described, per app.
  private var idMemory: [String: [Int: Attributes]] = [:]
  /// Apps whose raise we have already declined during the CURRENT parked
  /// episode. Cleared the moment the window is seen un-parked, so each new
  /// episode gets one refusal — see the "raise" case.
  private var refusedRaise: Set<String> = []
  /// Per app, the exact action that was last accepted and changed nothing.
  /// Sending it again is refused once — see repeatCheck.
  private var lastNoChange: [String: String] = [:]

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
      let opts = options(p)
      let snap = try backend.snapshot(app: app, options: opts)
      defer { store(app, opts, snap) }
      var out: [String: Any] = ["count": snap.nodes.count, "truncated": snap.truncated]
      if let prev = baseline(app, opts), !((p["full"] as? Bool) ?? false) {
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
      let opts = options(p)
      let snap = try backend.snapshot(app: app, options: opts)
      store(app, opts, snap)
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
      let key = Self.actionKey("act", id: id, detail: action)
      try repeatCheck(app, key)
      try backend.perform(app: app, id: id, action: action, keepFront: (p["keepFront"] as? Bool) ?? false)
      return try afterAction(app, p, refound: asked == id ? nil : (asked, id), actionKey: key)
    case "setValue":
      let asked = try int(p, "id"); let value = try string(p, "value")
      let id = try resolveId(app, asked)
      let key = Self.actionKey("setValue", id: id, detail: value)
      try repeatCheck(app, key)
      try backend.setValue(app: app, id: id, value: value, keepFront: (p["keepFront"] as? Bool) ?? false)
      // Read it back unless told not to. This throws BEFORE afterAction, so the
      // diff baseline is left where it was and the next read still shows what
      // the bad write did.
      // OPT-IN, deliberately. Shipped default-on and measured wrong the same
      // day: Figma's position steppers ignore an AXValue write entirely and
      // keep reporting the old value, so the read-back refused writes that had
      // landed elsewhere and taught the caller to distrust the bridge. It is
      // honest only where a write is actually observable — a `text field`,
      // which Figma does honour.
      if (p["verify"] as? Bool) == true { try verifyValue(app, id: id, wanted: value) }
      return try afterAction(app, p, refound: asked == id ? nil : (asked, id), actionKey: key)
    case "key":
      let key = try string(p, "key").lowercased()
      guard Self.keyAllowed(key) else {
        throw BridgeError.badParams("Unknown key \"\(key)\". Use one letter (a-z), one digit, or a named key: \(Self.keys.joined(separator: ", ")).")
      }
      let mods = try modifierList(p)
      let asked = p["id"] as? Int
      let focusId = try asked.map { try resolveId(app, $0) }
      // Keys are exempt from repeatCheck. An app that does not expose its
      // selection in the tree makes every arrow key look like a no-op, and
      // refusing the second one would break moving through a list — the very
      // path the parked-window advice sends callers down. The waste this rule
      // was built for was repeated PRESSES on dead controls, not keys.
      try backend.pressKey(app: app, key: key, modifiers: mods, focusId: focusId)
      return try afterAction(app, p, refound: asked == focusId ? nil : (asked!, focusId!), closing: key == "escape")
    case "type":
      // Text entry, not shortcuts. A whole string in one call, because a
      // design app's inspector wants four numbers per shape and one key per
      // step does not fit a batch: "-19.6875" alone is nine steps.
      guard let text = p["text"] as? String else {
        throw BridgeError.badParams("Missing required string param \"text\".")
      }
      guard !text.isEmpty else { throw BridgeError.badParams("text is empty; nothing to type.") }
      guard text.count <= Self.maxTypeLength else {
        throw BridgeError.badParams("text is \(text.count) characters; at most \(Self.maxTypeLength) per call.")
      }
      let typeAsked = p["id"] as? Int
      let typeFocus = try typeAsked.map { try resolveId(app, $0) }
      try backend.typeText(app: app, text: text, focusId: typeFocus)
      return try afterAction(app, p, refound: typeAsked == typeFocus ? nil : (typeAsked!, typeFocus!))
    case "raise":
      // Measured over six runs: a press does nothing because the window is
      // parked, and the caller raises to fix it. That cannot work. Raising
      // un-parks the window only while the app is in front, and it re-parks
      // the moment focus moves on — one run raised, and eleven seconds later
      // the next press was dead again with the same hint. Guidance did not
      // stop it: the hint, this tool's own description and the bundled skill
      // all said so. So the reflex is refused rather than described.
      //
      // The decision is the window's state NOW, not what the last action did.
      // An earlier version armed on a dead action and disarmed on a
      // successful one, which meant the keyboard workaround — the very thing
      // the refusal recommends — switched the guard off at the moment it
      // worked, and the reflex raise went straight through five seconds
      // later. Measured.
      //
      // One refusal per parked episode. A caller that means it, or a user who
      // asked to SEE the app, gets it on the second ask; un-parking re-arms it
      // for next time. This blocks the reflex, not the intent.
      //
      // The escape hatch is deliberately NOT mentioned in the message. An
      // earlier version ended with "ask again and it will go through", and the
      // model asked again five seconds later — measured. A refusal that
      // explains how to get around it is a speed bump, not a refusal.
      if backend.unresponsiveHint(app: app) != nil {
        if refusedRaise.insert(app).inserted {
          throw BridgeError.actionFailed("Raising \(app) will not fix a press that did nothing: the window re-parks as soon as focus moves on, so this costs the user their screen and changes nothing. Do the keyboard route instead — key \"down\", then key \"return\", in one call — or use a menu bar item.")
        }
      } else {
        refusedRaise.remove(app)
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
      let launchOpts = options(p)
      let snap = try backend.snapshot(app: app, options: launchOpts)
      store(app, launchOpts, snap)
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
    case "pointer":
      // Pointer input inside one element. The points are FRACTIONS of that
      // element's box, never screen pixels: the comparison run spent several
      // turns discovering a 2.8125 display scale factor and drawing outside
      // the frame, and a fraction of a known box cannot go wrong that way.
      // The result reports where each fraction actually landed.
      let anchor = try resolveId(app, try int(p, "id"))
      // No path at all means the middle of the element. Clicking a field to
      // put a caret in it is the commonest use by far, and spelling out
      // {"x":0.5,"y":0.5} for it is noise. A path that IS given must still be
      // well formed.
      let path = p["path"] == nil ? [] : try pathPoints(p)
      let hold = (p["hold"] as? Bool) ?? false
      let clicks = (p["clicks"] as? Int) ?? 1
      guard clicks >= 1, clicks <= Self.maxClicks else {
        throw BridgeError.badParams("clicks must be 1 to \(Self.maxClicks); 2 is a double click.")
      }
      // An empty path means "the middle of it", which is what a caller wanting
      // to click a field means, and saves writing {"x":0.5,"y":0.5} every time.
      let landed = try backend.pointer(app: app, id: anchor, path: path.isEmpty ? [(x: 0.5, y: 0.5)] : path,
                                       hold: hold, modifiers: try modifierList(p), clicks: clicks)
      var out = (try afterAction(app, p)) as? [String: Any] ?? [:]
      out["at"] = landed.map { ["x": Int($0.x), "y": Int($0.y)] }
      return out
    case "values":
      // Read back a handful of ids in one call: the value is a fresh attribute
      // read, role and title are what the id last described (idMemory). Measured
      // 2026-09-08: 32 finds in one Figma run existed to check fields a batch
      // had just written — a whole model turn each.
      guard let raw = p["ids"] as? [Int], !raw.isEmpty else {
        throw BridgeError.badParams("Pass ids: a non-empty list of element ids.")
      }
      guard raw.count <= Self.maxValueIds else {
        throw BridgeError.badParams("\(raw.count) ids is too many (max \(Self.maxValueIds)).")
      }
      return ["values": raw.map { id -> [String: Any] in
        let attrs = idMemory[app]?[id]
        let value = (try? backend.value(app: app, id: id)) ?? nil
        return ["id": id, "role": attrs?.role ?? NSNull(), "title": attrs?.title ?? NSNull(), "value": value ?? NSNull()]
      }]
    case "scroll":
      let id = try resolveId(app, try int(p, "id"))
      let dy = (p["dy"] as? Int) ?? 0
      let dx = (p["dx"] as? Int) ?? 0
      guard dx != 0 || dy != 0 else { throw BridgeError.badParams("Pass a non-zero dx or dy. Negative dy scrolls down, positive up.") }
      let scrollKey = Self.actionKey("scroll", id: id, detail: "\(dx),\(dy)")
      try repeatCheck(app, scrollKey)
      try backend.scroll(app: app, id: id, dx: dx, dy: dy)
      return try afterAction(app, p, actionKey: scrollKey)
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
  private func afterAction(_ app: String, _ p: [String: Any], refound: (from: Int, to: Int)? = nil, actionKey: String? = nil, closing: Bool = false) throws -> Any {
    // `"settle": false` means the caller is mid-sequence and does not want a
    // diff for this step: do the action and return. Measured on a Figma icon
    // built out of inspector fields — 372 actions, 253 seconds of settle
    // waiting, a fifth of the run — where every step of a five-step batch paid
    // for a reaction nobody read, because the batch reports its NET effect at
    // the end. The baseline is deliberately left alone, so that closing read
    // measures the whole sequence rather than only its last step.
    if (p["settle"] as? Bool) == false {
      return ["ok": true, "settled": false]
    }
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
    if let prev = baseline(app, opts) {
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
        // Only a SUBSTANTIAL shrink counts as a transition. The rule was
        // tuned on Maps, where pressing a result collapses a whole list of
        // rows before the place card arrives; in Figma every selection change
        // and closing panel loses a handful of rows and nothing else is
        // coming, so a bare "fewer nodes" test paid the long deadline over and
        // over — measured at 17 waits over three seconds, 94 seconds of
        // waiting in one task. A list collapsing loses tens of nodes; a panel
        // tidying itself loses a few.
        let lost = prev.nodes.count - snap.nodes.count
        // `closing`: the action's whole purpose was to make the tree smaller —
        // escape dismissing a panel — so a shrink IS the settled state. Measured
        // 2026-09-08: eight escapes after Figma's colour picker, 3.5s each.
        let shrank = !closing && lost >= Self.shrinkNodes && lost * 10 >= prev.nodes.count
        if elapsed >= (shrank ? Self.settleDeadlineShrunk : Self.settleDeadline) { break }
        if reacted && !shrank && stableLooks >= 1 && elapsed >= Self.settleFloor { break }
        Thread.sleep(forTimeInterval: Self.settleStep)
        let again = try backend.snapshot(app: app, options: opts)
        stableLooks = Differ.changed(from: snap, to: again) ? 0 : stableLooks + 1
        snap = again
      }
      waitedMs = Int(Date().timeIntervalSince(started) * 1000)
    }
    let diff = baseline(app, opts).map { Differ.render(from: $0, to: snap, geometry: false) } ?? Formatter.render(snap, geometry: false)
    store(app, opts, snap)
    var out: [String: Any] = ["ok": true, "diff": diff, "waitedMs": waitedMs]
    if let refound {
      // Say it plainly: the caller's number is stale from here on, and the
      // reason its next read looks renumbered is this, not a phantom.
      out["refoundId"] = refound.to
      out["note"] = "Element \(refound.from) was gone; the same control is now \(refound.to) and that is what was acted on. Use \(refound.to) from here."
    }
    // Nothing moved: if the backend knows why this app ignores presses, say so
    // now, before the model retries the same control four different ways.
    if diff == "(no changes)" {
      if let why = backend.unresponsiveHint(app: app) { out["hint"] = why }
      if let actionKey { lastNoChange[app] = actionKey }
    } else {
      lastNoChange.removeValue(forKey: app)
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
  /// How many nodes an app must lose before the tree counts as in transition
  /// rather than merely tidier. Both this and a tenth of the tree must go.
  static let shrinkNodes = 10
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
  private func modifierList(_ p: [String: Any]) throws -> [String] {
    guard let raw = p["modifiers"] else { return [] }
    guard let list = raw as? [String] else { throw BridgeError.badParams("modifiers must be a list of strings.") }
    for m in list where !Self.modifiers.contains(m) {
      throw BridgeError.badParams("Unknown modifier \"\(m)\". Modifiers: \(Self.modifiers.joined(separator: ", ")).")
    }
    return list
  }

  /// Fractions, validated. Anything outside 0-1 is refused with the reason,
  /// because the alternative is a click landing somewhere nobody chose.
  private func pathPoints(_ p: [String: Any]) throws -> [(x: Double, y: Double)] {
    guard let raw = p["path"] as? [[String: Any]], !raw.isEmpty else {
      throw BridgeError.badParams("Pass path: a list of {x, y} points, each a FRACTION 0-1 of the anchor element's box. [{\"x\":0.5,\"y\":0.5}] is its centre.")
    }
    guard raw.count <= Self.maxPathPoints else {
      throw BridgeError.badParams("\(raw.count) points is too many (max \(Self.maxPathPoints)).")
    }
    var out: [(x: Double, y: Double)] = []
    for (i, pt) in raw.enumerated() {
      let x = (pt["x"] as? Double) ?? (pt["x"] as? Int).map(Double.init)
      let y = (pt["y"] as? Double) ?? (pt["y"] as? Int).map(Double.init)
      guard let x, let y else { throw BridgeError.badParams("point \(i + 1) needs numeric x and y.") }
      guard x >= 0, x <= 1, y >= 0, y <= 1 else {
        throw BridgeError.badParams("point \(i + 1) is (\(x), \(y)). x and y are FRACTIONS of the anchor element's box, so both must be between 0 and 1.")
      }
      out.append((x, y))
    }
    return out
  }

  private func resolveId(_ app: String, _ id: Int) throws -> Int {
    guard let snap = latest[app] else { throw BridgeError.noSuchElement(id) }
    // Ids come from the per-app registry, so one seen under ANY filter names a
    // real element, whatever filter the most recent read used.
    if snapshots(app).contains(where: { $0.nodes.contains { $0.id == id } }) { return id }
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
  private static func filterKey(_ o: SnapshotOptions) -> String {
    "d\(o.maxDepth)m\(o.maxElements)i\(o.interactiveOnly)w\(o.webContent)"
  }
  private func baseline(_ app: String, _ o: SnapshotOptions) -> Snapshot? { baselines[app]?[Self.filterKey(o)] }
  private func store(_ app: String, _ o: SnapshotOptions, _ snap: Snapshot) {
    var perApp = baselines[app] ?? [:]
    perApp[Self.filterKey(o)] = snap
    baselines[app] = perApp
    latest[app] = snap
    remember(app, snap)
  }
  /// Every snapshot this app currently has a baseline for, one per filter.
  private func snapshots(_ app: String) -> [Snapshot] { Array((baselines[app] ?? [:]).values) }

  private func remember(_ app: String, _ snap: Snapshot) {
    var mem = idMemory[app] ?? [:]
    for n in snap.nodes where Self.identifiable(n.attributes) { mem[n.id] = n.attributes }
    if mem.count > Self.idMemoryCap {
      for id in mem.keys.sorted().prefix(mem.count - Self.idMemoryCap) { mem.removeValue(forKey: id) }
    }
    idMemory[app] = mem
  }
  static let idMemoryCap = 6_000

  /// One action, as a string, so "the same thing again" is expressible.
  private static func actionKey(_ verb: String, id: Int?, detail: String) -> String {
    "\(verb)|\(id.map(String.init(describing:)) ?? "-")|\(detail)"
  }

  /// The same action, on the same element, after it was accepted and changed
  /// nothing. Measured: one run pressed the same dead control twice in a row,
  /// and others pressed one four different ways. Repeating an action that
  /// demonstrably did nothing cannot do anything, so it is refused.
  ///
  /// Refused ONCE, then cleared, so an action the app has since become ready
  /// for is not blocked forever — and, like the raise, the message does not
  /// mention that.
  ///
  /// Two things this deliberately does NOT catch. An action that DID change
  /// something, repeated: pressing a tab back and forth changes the tree every
  /// time, so it is indistinguishable here from useful work, and that waste is
  /// a question of scope rather than of mechanism. And keys, which are exempt
  /// at the call site — see the "key" case.
  /// Tolerance for a numeric read-back, absolute and relative. A field that
  /// ROUNDS what it was given is working correctly: Figma shows 160.31 for a
  /// 160.3125 it stored exactly, and demanding equality there would refuse
  /// every fractional coordinate.
  static let verifyAbs = 0.05
  static let verifyRel = 0.001

  /// Prove the write landed, or say what is there instead. Deliberately
  /// one-sided: it fails only on evidence, never on a value it cannot compare.
  /// Two kinds of evidence, both measured in Figma:
  ///
  /// - Both sides are numbers and differ beyond rounding. Setting 180 on a
  ///   field still holding 120 produced 120180 — twice in one task — and the
  ///   seventeen coordinates computed after it were all wrong.
  /// - The value is what was asked for with the OLD text still glued to it,
  ///   even when the result is not a number.
  ///
  /// Anything else passes: a field that normalises "100" to "100%", reformats
  /// a date, or exposes no value at all is not a failure, and a guard that
  /// stops on those would be worse than no guard.
  func verifyValue(_ app: String, id: Int, wanted: String) throws {
    guard let actual = try backend.value(app: app, id: id), actual != wanted else { return }
    let w = wanted.trimmingCharacters(in: .whitespaces)
    let a = actual.trimmingCharacters(in: .whitespaces)
    if a == w { return }
    func fail(_ why: String) throws -> Never {
      // The remedy CLICKS the field first. An earlier version opened with
      // command+a and delete, and when focus is not inside a field that
      // selects every layer in the document and deletes them — measured, it
      // cleared a canvas mid-task. Clicking puts the caret in the field, so
      // the select-all that follows is scoped to it.
      throw BridgeError.actionFailed(
        "setValue did not land: asked for \"\(wanted)\", the field now reads \"\(actual)\" (\(why)). "
        + "Nothing after this was run. Click into the field, select its contents, then type: "
        + "computer_do {\"app\":\"\(app)\",\"steps\":[{\"do\":\"pointer\",\"id\":\(id)},{\"do\":\"key\",\"key\":\"a\",\"modifiers\":[\"command\"]},{\"do\":\"type\",\"text\":\"\(wanted)\"},{\"do\":\"key\",\"key\":\"return\"}]}")
    }
    if let wn = Double(w), let an = Double(a) {
      let slack = max(Self.verifyAbs, abs(wn) * Self.verifyRel)
      if abs(wn - an) > slack { try fail("off by \(abs(wn - an)), beyond rounding") }
      return
    }
    // The append signature without numbers: the old content is still in FRONT
    // of what was just written, which is where an uncleared field leaves it —
    // the caret sits at the end, so the new text lands after the old.
    //
    // Only that direction. A value ENDING in extra characters is how a field
    // reports its own formatting: "100" comes back "100%", "12" comes back
    // "12px". An earlier version of this check also matched a longer value
    // that merely started with what was asked for, and refused every one of
    // those — caught by the normalisation test below, not by a live run.
    if a.count > w.count, a.hasSuffix(w) { try fail("the old text was not replaced") }
  }

  private func repeatCheck(_ app: String, _ key: String) throws {
    guard lastNoChange[app] == key else { return }
    lastNoChange.removeValue(forKey: app)
    throw BridgeError.actionFailed("You already sent this exact action and it was accepted without changing anything. Sending it again will do the same. Take a different path — the keyboard, or a menu bar item — or read the app to see what is actually there.")
  }

  /// An action the element did not list is refused before it is tried. Run 4
  /// of the Maps task: the model pressed a tab button whose line showed no
  /// actions at all; AXPress returned success and nothing happened, and the
  /// model spent four turns finding that out. Only a non-empty list is
  /// trusted here — an empty one may mean the actions were never fetched.
  private func offers(_ app: String, _ id: Int, _ action: String) throws {
    let node = latest[app]?.nodes.first(where: { $0.id == id })
      ?? snapshots(app).lazy.compactMap({ $0.nodes.first(where: { $0.id == id }) }).first
    guard let node, !node.attributes.actions.isEmpty, !node.attributes.actions.contains(action) else { return }
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
