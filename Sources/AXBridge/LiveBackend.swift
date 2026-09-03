import AppKit
import ApplicationServices
import AXModel

/// The live adapter. Task 7 ships trust + apps; Tasks 8–9 fill in the rest.
public final class LiveBackend: Backend {
  public init() {}

  public func isTrusted() -> Bool { AXIsProcessTrusted() }

  public func apps() -> [AppInfo] {
    NSWorkspace.shared.runningApplications
      .filter { $0.activationPolicy == .regular }
      .map { AppInfo(pid: $0.processIdentifier, name: $0.localizedName ?? "?", bundleId: $0.bundleIdentifier, frontmost: $0.isActive) }
  }

  public func windows(app: String) throws -> [WindowInfo] { throw BridgeError.actionFailed("not implemented yet") }
  public func snapshot(app: String, options: SnapshotOptions) throws -> Snapshot { throw BridgeError.actionFailed("not implemented yet") }
  public func perform(app: String, id: Int, action: String) throws { throw BridgeError.actionFailed("not implemented yet") }
  public func setValue(app: String, id: Int, value: String) throws { throw BridgeError.actionFailed("not implemented yet") }
  public func raise(app: String, windowId: Int?) throws { throw BridgeError.actionFailed("not implemented yet") }
}
