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

  public func snapshot(app: String, options: SnapshotOptions) throws -> Snapshot {
    let a = try resolve(app)
    let root = appElement(a)
    var reg = registries[a.processIdentifier] ?? IdRegistry()
    let snap = Snapshot.build(root: root, source: LiveSource(), registry: &reg, options: options)
    registries[a.processIdentifier] = reg
    var map: [Int: AXElement] = [:]
    for n in snap.nodes { if let el = reg.identity(for: n.id)?.base as? AXElement { map[n.id] = el } }
    elements[a.processIdentifier] = map
    return snap
  }

  public func perform(app: String, id: Int, action: String) throws { throw BridgeError.actionFailed("not implemented yet") }
  public func setValue(app: String, id: Int, value: String) throws { throw BridgeError.actionFailed("not implemented yet") }
  public func raise(app: String, windowId: Int?) throws { throw BridgeError.actionFailed("not implemented yet") }
}
