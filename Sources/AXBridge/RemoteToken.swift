import ApplicationServices
import CoreGraphics
import Darwin
import Foundation

/// The private HIServices calls that reach a window on another Space. AXWindows
/// lists only the current Space; an element built from a remote token answers
/// wherever its window is. Measured 2026-09-04 (docs/plans/2026-09-04-cross-space-design.md):
/// reads, web content and a focus action all work off-Space with the frontmost
/// app unchanged, and the element is CFEqual to the public one, so ids hold.
///
/// Token layout, little-endian: pid @0, 0 @4, 'coco' @8, the app's INTERNAL
/// element id @12 (not the CGWindowID — Chrome's window 104 was element 209),
/// 0 @16. Every symbol is resolved with dlsym so a macOS that drops one leaves
/// the bridge running with cross-Space off, not failing to launch.
enum RemoteToken {
  private typealias Create = @convention(c) (CFData) -> Unmanaged<AXUIElement>?
  private typealias TokenOf = @convention(c) (AXUIElement) -> Unmanaged<CFData>?
  private typealias WindowOf = @convention(c) (AXUIElement, UnsafeMutablePointer<CGWindowID>) -> AXError

  private static func sym<T>(_ name: String, as: T.Type) -> T? {
    guard let p = dlsym(UnsafeMutableRawPointer(bitPattern: -2), name) else { return nil } // RTLD_DEFAULT
    return unsafeBitCast(p, to: T.self)
  }
  private static let create = sym("_AXUIElementCreateWithRemoteToken", as: Create.self)
  private static let tokenOf = sym("_AXUIElementRemoteTokenCreate", as: TokenOf.self)
  private static let windowOf = sym("_AXUIElementGetWindow", as: WindowOf.self)

  static var available: Bool { create != nil && tokenOf != nil && windowOf != nil }
  private static let tag: UInt32 = 0x636f636f // 'coco'
  /// The bridge's per-message AX timeout. One unresponsive app must never hang
  /// the whole bridge; a token-built element does not inherit the app element's
  /// setting, so it is applied here as well as in LiveBackend.appElement.
  static let messagingTimeout: Float = 1.0

  /// The element with this internal id, or nil if the symbol is missing or
  /// HIServices rejects the token. The element may still be invalid — the first
  /// attribute read says (-25202).
  static func element(pid: pid_t, elementId: UInt32) -> AXUIElement? {
    guard let create else { return nil }
    var d = Data(count: 20)
    d.withUnsafeMutableBytes { (b: UnsafeMutableRawBufferPointer) in
      b.storeBytes(of: UInt32(bitPattern: pid), toByteOffset: 0, as: UInt32.self)
      b.storeBytes(of: tag, toByteOffset: 8, as: UInt32.self)
      b.storeBytes(of: elementId, toByteOffset: 12, as: UInt32.self)
    }
    guard let el = create(d as CFData)?.takeRetainedValue() else { return nil }
    AXUIElementSetMessagingTimeout(el, Self.messagingTimeout)
    return el
  }

  /// The window-server id behind a window element.
  static func windowId(of el: AXUIElement) -> CGWindowID? {
    guard let windowOf else { return nil }
    var w: CGWindowID = 0
    return windowOf(el, &w) == .success ? w : nil
  }

  /// The internal element id inside an existing element's token, or nil when
  /// the token is not the 20-byte 'coco' shape this code understands.
  static func elementId(of el: AXUIElement) -> UInt32? {
    guard let tokenOf, let t = tokenOf(el)?.takeRetainedValue() else { return nil }
    let d = t as Data
    guard d.count == 20 else { return nil }
    let seen = d.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 8, as: UInt32.self) }
    guard seen == tag else { return nil }
    return d.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 12, as: UInt32.self) }
  }
}
