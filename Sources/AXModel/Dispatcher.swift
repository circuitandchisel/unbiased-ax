import Foundation

/// One request line in, one response line out. Holds the last snapshot per
/// app so `tree` can answer with a diff and `act` can refuse ids the model
/// never saw. Foundation is imported here for JSONSerialization only; the
/// rest of AXModel stays framework-free.
public final class Dispatcher {
  public static let methods = ["hello", "apps", "windows", "tree", "find", "act", "setValue", "raise"]

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
    case "windows":
      let wins = try backend.windows(app: app)
      return ["windows": wins.map(asDict), "text": wins.map(\.line).joined(separator: "\n")]
    case "tree":
      let snap = try backend.snapshot(app: app, options: options(p))
      defer { last[app] = snap }
      if let prev = last[app], !((p["full"] as? Bool) ?? false) {
        return ["diff": Differ.render(from: prev, to: snap, geometry: geometry), "count": snap.nodes.count, "truncated": snap.truncated]
      }
      return ["tree": Formatter.render(snap, geometry: geometry), "count": snap.nodes.count, "truncated": snap.truncated]
    case "find":
      let snap = try backend.snapshot(app: app, options: options(p))
      last[app] = snap
      let role = p["role"] as? String
      let needle = (p["title"] as? String)?.lowercased()
      let hits = snap.nodes.filter { n in
        (role == nil || n.attributes.role == role!) &&
        (needle == nil || (n.attributes.title ?? "").lowercased().contains(needle!) || (n.attributes.value ?? "").lowercased().contains(needle!))
      }
      return ["matches": hits.map { Formatter.line($0, geometry: geometry) }, "count": hits.count]
    case "act":
      let id = try int(p, "id"); let action = try string(p, "action")
      try known(app, id)
      try backend.perform(app: app, id: id, action: action)
      return try afterAction(app, p)
    case "setValue":
      let id = try int(p, "id"); let value = try string(p, "value")
      try known(app, id)
      try backend.setValue(app: app, id: id, value: value)
      return try afterAction(app, p)
    case "raise":
      try backend.raise(app: app, windowId: p["window"] as? Int)
      return try afterAction(app, p)
    default:
      throw BridgeError.unknownMethod(method)
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
