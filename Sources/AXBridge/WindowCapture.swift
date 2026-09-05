import AppKit
import AXModel
import CoreGraphics
import ScreenCaptureKit

/// A picture of one window by window-server id, taken through ScreenCaptureKit
/// with a filter for that window alone. This reaches windows on other Spaces:
/// measured 2026-09-05, Maps' window on another Space came back in 72ms as a
/// real image of its UI while Brave stayed frontmost. What the app does not
/// draw while hidden (Maps' tiles) is black in it; the controls are not.
///
/// Captured at 1x. The model reads controls and text, not pixels, and a 2x
/// capture of a 1024x768 window was 361KB of PNG against ~90KB at 1x.
@available(macOS 14, *)
enum WindowCapture {
  static let timeout: TimeInterval = 5
  static let jpegQuality: Double = 0.7

  static func capture(cgWindow: CGWindowID, info: WindowInfo) throws -> WindowShot {
    // A stdio tool has no window-server connection until something opens one;
    // ScreenCaptureKit asserts (CGS_REQUIRE_INIT) rather than opening it.
    _ = CGMainDisplayID()
    var result: Result<WindowShot, Error>?
    let done = DispatchSemaphore(value: 0)
    Task {
      do {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
        guard let w = content.windows.first(where: { $0.windowID == cgWindow }) else {
          throw BridgeError.actionFailed("the window server no longer lists that window")
        }
        let cfg = SCStreamConfiguration()
        cfg.width = max(1, Int(w.frame.width))
        cfg.height = max(1, Int(w.frame.height))
        cfg.showsCursor = false
        let img = try await SCScreenshotManager.captureImage(contentFilter: SCContentFilter(desktopIndependentWindow: w), configuration: cfg)
        // JPEG: the first live use returned an 880KB PNG of a 1024x768 window,
        // most of it the photos on a place card, and every picture is re-sent
        // with the transcript on every later turn. The same frame as JPEG at
        // this quality is a tenth of that, and the model reads text and
        // controls, not gradients.
        guard let jpeg = NSBitmapImageRep(cgImage: img).representation(using: .jpeg, properties: [.compressionFactor: Self.jpegQuality]) else {
          throw BridgeError.actionFailed("could not encode the capture")
        }
        result = .success(WindowShot(image: jpeg, mime: "image/jpeg", width: img.width, height: img.height, windowId: info.id, onSpace: info.onSpace))
      } catch let e as BridgeError {
        result = .failure(e)
      } catch {
        // SCStreamErrorDomain -3801 is the user having declined Screen Recording.
        let ns = error as NSError
        let why = ns.domain.contains("SCStream") || ns.code == -3801
          ? "Screen Recording is not granted for this app. Allow it in System Settings > Privacy & Security > Screen Recording, then try again."
          : "window capture failed: \(error.localizedDescription)"
        result = .failure(BridgeError.actionFailed(why))
      }
      done.signal()
    }
    guard done.wait(timeout: .now() + timeout) == .success, let r = result else { throw BridgeError.timeout("window capture") }
    return try r.get()
  }
}
