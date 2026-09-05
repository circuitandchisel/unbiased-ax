import AppKit
import AXModel
import CoreGraphics
import ScreenCaptureKit

/// A picture of one window by window-server id, taken through ScreenCaptureKit
/// with a filter for that window alone. This reaches windows on other Spaces:
/// measured 2026-09-05, Maps' window on another Space came back in ~100ms as a
/// real image of its UI while another app stayed frontmost. What the app has
/// never drawn (a window never shown since launch; Maps' tiles while hidden)
/// is blank in it; the controls are not.
///
/// The capture runs in a HELPER PROCESS — this same executable with
/// `--capture <windowID>`. Measured: the identical ScreenCaptureKit calls
/// answer in ~100ms in a fresh process every time, and in the bridge process
/// itself they answered once in 128ms and otherwise never (shareable content
/// arrives, the image request does not), with both the async and the
/// completion-handler API, with and without the main run loop pumped. The
/// bridge process is full of Accessibility state that a fresh one is not;
/// isolating the capture costs ~150ms of process spawn and removes the
/// question.
///
/// JPEG at 1x: the first live use returned an 880KB PNG of a 1024x768 window,
/// re-sent with the transcript on every later turn; the same frame as JPEG
/// here is a tenth of that, and the model reads text and controls, not pixels.
public enum WindowCapture {
  static let timeout: TimeInterval = 8
  static let jpegQuality: Double = 0.7
  static let flag = "--capture"
  static let helperName = "unbiased-ax-capture"

  // MARK: parent side

  static func capture(cgWindow: CGWindowID, info: WindowInfo) throws -> WindowShot {
    guard let exe = Bundle.main.executableURL else { throw BridgeError.actionFailed("cannot locate the bridge executable for the capture helper") }
    // Prefer the sibling copy the bundle ships (see scripts/bundle.sh: it has
    // no privacy record of its own, so the capture is attributed to the app
    // that spawned the bridge). A bare build has no sibling and uses itself.
    let sibling = exe.deletingLastPathComponent().appendingPathComponent(Self.helperName)
    let proc = Process()
    proc.executableURL = FileManager.default.isExecutableFile(atPath: sibling.path) ? sibling : exe
    proc.arguments = [Self.flag, String(cgWindow)]
    let out = Pipe()
    proc.standardOutput = out
    proc.standardError = FileHandle.nullDevice
    do { try proc.run() } catch { throw BridgeError.actionFailed("could not start the capture helper: \(error.localizedDescription)") }
    // Read to EOF on a background thread so a large image cannot fill the pipe
    // and deadlock against waitUntilExit.
    var data = Data()
    let reader = Thread { data = out.fileHandleForReading.readDataToEndOfFile() }
    reader.start()
    let deadline = Date().addingTimeInterval(timeout)
    while proc.isRunning && Date() < deadline { Thread.sleep(forTimeInterval: 0.02) }
    if proc.isRunning {
      proc.terminate()
      // Measured: this is what a missing Screen Recording grant looks like —
      // ScreenCaptureKit neither errors nor answers.
      throw BridgeError.actionFailed("Window capture did not finish. This is what a missing Screen Recording permission looks like: allow it for the app in System Settings > Privacy & Security > Screen Recording (macOS may be showing that prompt now), then try again.")
    }
    while reader.isExecuting { Thread.sleep(forTimeInterval: 0.005) }
    guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
      throw BridgeError.actionFailed("the capture helper returned nothing usable (exit \(proc.terminationStatus))")
    }
    if let why = json["error"] as? String { throw BridgeError.actionFailed(why) }
    guard let b64 = json["image"] as? String, let image = Data(base64Encoded: b64),
          let width = json["width"] as? Int, let height = json["height"] as? Int else {
      throw BridgeError.actionFailed("the capture helper returned an incomplete result")
    }
    return WindowShot(image: image, mime: "image/jpeg", width: width, height: height, windowId: info.id, onSpace: info.onSpace)
  }

  // MARK: helper side

  /// True when this process was started as the capture helper; `helperMain`
  /// then does the one capture and exits.
  public static func isHelperInvocation(_ args: [String]) -> Bool { args.count >= 3 && args[1] == flag }

  /// Writes one JSON object to stdout: {image (base64 JPEG), width, height}
  /// or {error}. Never returns.
  public static func helperMain(_ args: [String]) -> Never {
    func emit(_ obj: [String: Any]) -> Never {
      if let d = try? JSONSerialization.data(withJSONObject: obj) { FileHandle.standardOutput.write(d) }
      exit(0)
    }
    guard let wid = UInt32(args[2]) else { emit(["error": "bad window id"]) }
    guard #available(macOS 14, *) else { emit(["error": "window capture needs macOS 14 or later"]) }
    // A stdio tool has no window-server connection until something opens one;
    // ScreenCaptureKit asserts (CGS_REQUIRE_INIT) rather than opening it.
    _ = CGMainDisplayID()
    let done = DispatchSemaphore(value: 0)
    var result: [String: Any] = ["error": "no result"]
    Task {
      do {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
        guard let w = content.windows.first(where: { $0.windowID == CGWindowID(wid) }) else {
          result = ["error": "the window server no longer lists that window"]; done.signal(); return
        }
        let cfg = SCStreamConfiguration()
        cfg.width = max(1, Int(w.frame.width))
        cfg.height = max(1, Int(w.frame.height))
        cfg.showsCursor = false
        let img = try await SCScreenshotManager.captureImage(contentFilter: SCContentFilter(desktopIndependentWindow: w), configuration: cfg)
        guard let jpeg = NSBitmapImageRep(cgImage: img).representation(using: .jpeg, properties: [.compressionFactor: jpegQuality]) else {
          result = ["error": "could not encode the capture"]; done.signal(); return
        }
        result = ["image": jpeg.base64EncodedString(), "width": img.width, "height": img.height]
      } catch {
        let ns = error as NSError
        // SCStreamErrorDomain -3801 is the user having declined Screen Recording.
        result = ["error": ns.domain.contains("SCStream") || ns.code == -3801
          ? "Screen Recording is not granted for this app. Allow it in System Settings > Privacy & Security > Screen Recording, then try again."
          : "window capture failed: \(error.localizedDescription)"]
      }
      done.signal()
    }
    _ = done.wait(timeout: .now() + timeout)
    emit(result)
  }
}
