import Foundation

/// One request line in, one response line out. Holds the last snapshot per
/// app so `tree` can answer with a diff and `act` can refuse ids the model
/// never saw. Foundation is imported here for JSONSerialization only; the
/// rest of AXModel stays framework-free.
public final class Dispatcher {
  public static let methods = ["hello", "apps", "windows", "tree", "find", "act", "setValue", "key", "raise", "icon", "launch", "scroll"]
  public static let keys = ["return", "tab", "escape", "space", "delete", "up", "down", "left", "right"]

  private let backend: Backend
  private var last: [String: Snapshot] = [:]

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
      return ["name": "unbiased-ax", "protocolVersion": protocolVersion, "trusted": backend.isTrusted()]
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
      try annotateSpaces(&out, app: app, windowsHere: wins.count)
      return out
    case "tree":
      let snap = try backend.snapshot(app: app, options: options(p))
      defer { last[app] = snap }
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
      try annotateSpaces(&out, app: app, windowsHere: try backend.windows(app: app).count)
      return out
    case "find":
      let snap = try backend.snapshot(app: app, options: options(p))
      last[app] = snap
      let role = p["role"] as? String
      let needle = (p["title"] as? String)?.lowercased()
      let hits = snap.nodes.filter { n in
        (role == nil || n.attributes.role == role!) &&
        (needle == nil || (n.attributes.title ?? "").lowercased().contains(needle!) || (n.attributes.value ?? "").lowercased().contains(needle!))
      }
      var out: [String: Any] = ["matches": hits.map { Formatter.line($0, geometry: geometry) }, "count": hits.count]
      try annotateSpaces(&out, app: app, windowsHere: try backend.windows(app: app).count)
      return out
    case "act":
      let id = try int(p, "id"); let action = try string(p, "action")
      try known(app, id)
      try backend.perform(app: app, id: id, action: action, keepFront: (p["keepFront"] as? Bool) ?? false)
      return try afterAction(app, p)
    case "setValue":
      let id = try int(p, "id"); let value = try string(p, "value")
      try known(app, id)
      try backend.setValue(app: app, id: id, value: value, keepFront: (p["keepFront"] as? Bool) ?? false)
      return try afterAction(app, p)
    case "key":
      let key = try string(p, "key").lowercased()
      guard Self.keys.contains(key) else { throw BridgeError.badParams("Unknown key \"\(key)\". Keys: \(Self.keys.joined(separator: ", ")).") }
      let focusId = p["id"] as? Int
      if let id = focusId { try known(app, id) }
      try backend.pressKey(app: app, key: key, focusId: focusId)
      return try afterAction(app, p)
    case "raise":
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
      last[app] = snap
      var out: [String: Any] = [
        "ok": true,
        "alreadyRunning": alreadyRunning,
        "tree": Formatter.render(snap, geometry: false),
        "count": snap.nodes.count,
      ]
      try annotateSpaces(&out, app: app, windowsHere: try backend.windows(app: app).count)
      return out
    case "scroll":
      let id = try int(p, "id")
      try known(app, id)
      let dy = (p["dy"] as? Int) ?? 0
      let dx = (p["dx"] as? Int) ?? 0
      guard dx != 0 || dy != 0 else { throw BridgeError.badParams("Pass a non-zero dx or dy. Negative dy scrolls down, positive up.") }
      try backend.scroll(app: app, id: id, dx: dx, dy: dy)
      return try afterAction(app, p)
    default:
      throw BridgeError.unknownMethod(method)
    }
  }

  /// Off-Space windows, and what to do about them. AXWindows only lists the
  /// current Space, so "no windows" and "windows elsewhere" look identical in
  /// a tree; this is the only thing that tells them apart. The advice differs
  /// by whether anything readable is HERE, because that is what decides
  /// whether raising is necessary or gratuitous: with a window on this Space
  /// the model raised for no reason and took the user's screen; with none, no
  /// amount of reading finds the window — a model spent six minutes proving
  /// that, and another lost the task to a shell.
  private func annotateSpaces(_ out: inout [String: Any], app: String, windowsHere: Int) throws {
    let off = try backend.offscreenWindows(app: app)
    out["offscreen"] = off
    guard off > 0 else { return }
    if windowsHere == 0 {
      out["hint"] = "This app's \(off) window(s) are all on another Space or hidden. They are NOT in the tree and cannot be read or acted on from here: call raise for this app first, then read again."
    } else {
      out["hint"] = "\(off) further window(s) are on another Space or hidden. The window(s) here are readable — work with those; do not raise."
    }
  }

  /// Re-snapshot and return the diff: the model sees what its action did
  /// without spending a second round-trip to look.
  private func afterAction(_ app: String, _ p: [String: Any]) throws -> Any {
    let snap = try backend.snapshot(app: app, options: options(p))
    let diff = last[app].map { Differ.render(from: $0, to: snap, geometry: false) } ?? Formatter.render(snap, geometry: false)
    last[app] = snap
    return ["ok": true, "diff": diff]
  }

  private func known(_ app: String, _ id: Int) throws {
    guard let snap = last[app], snap.nodes.contains(where: { $0.id == id }) else { throw BridgeError.noSuchElement(id) }
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
