import AppKit
import AXModel
import CoreGraphics
import Foundation

/// A pointer drawn where the agent is working, so the user can see what it is
/// doing without it touching their own cursor.
///
/// Since clicks stopped moving the real pointer there is nothing on screen to
/// watch: a window changes and no one can tell why. This puts a mark back —
/// but a drawn one, in its own window, which cannot be clicked and never takes
/// focus. It is a picture of what is happening, not a second input device.
///
/// It runs as a separate process for the same reason the capture helper does:
/// the bridge is a stdin loop with no run loop, and a window needs one. Keeping
/// the drawing out of the bridge means the bridge stays a stdin loop, and an
/// overlay that wedges or crashes costs a picture rather than the ability to
/// click. Same binary, started with a flag, fed points on its stdin.
public enum AgentCursor {
  static let flag = "--agent-cursor"
  /// The glow's colour. Deliberately the product's own, so a mark on screen
  /// reads as this app working rather than as an artefact of the OS.
  static let accent = NSColor(srgbRed: 0xFF / 255.0, green: 0x77 / 255.0, blue: 0x64 / 255.0, alpha: 1)
  /// Wide enough for the glow to fall off to nothing inside the window; the
  /// arrow's tip sits at the middle.
  static let side: CGFloat = 132
  /// Idle time before it fades. Long enough to bridge the pause between the
  /// points of a traced path, short enough not to linger once a run is done.
  static let idleSeconds: TimeInterval = 1.4

  // ── the bridge's side ─────────────────────────────────────────────────────

  private static var helper: Process?
  private static var toHelper: FileHandle?
  private static let lock = NSLock()

  public static var enabled = AgentCursorSwitch.enabled(ProcessInfo.processInfo.environment)

  /// Show the pointer at a screen point, in the CG coordinates everything else
  /// in this bridge uses — top-left origin, y downwards.
  public static func show(at p: CGPoint) {
    guard enabled else { return }
    send("\(p.x) \(p.y)\n")
  }

  /// Let it fade. Called when a path is finished rather than after each of its
  /// points, so it stays lit for the length of a drawing.
  public static func done() {
    guard enabled else { return }
    send("done\n")
  }

  private static func send(_ line: String) {
    lock.lock()
    defer { lock.unlock() }
    if helper == nil || helper?.isRunning != true { start() }
    guard let toHelper, let data = line.data(using: .utf8) else { return }
    // A helper that has gone away must never take the bridge with it: writing
    // to a closed pipe raises SIGPIPE, and one drawn pointer is not worth a
    // crash in the middle of someone's drawing.
    _ = try? toHelper.write(contentsOf: data)
  }

  private static func start() {
    let exe = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath()
    let p = Process()
    p.executableURL = exe
    p.arguments = [flag]
    let pipe = Pipe()
    p.standardInput = pipe
    p.standardOutput = FileHandle.nullDevice
    p.standardError = FileHandle.nullDevice
    do { try p.run() } catch { helper = nil; toHelper = nil; return }
    helper = p
    toHelper = pipe.fileHandleForWriting
  }

  // ── the helper's side ─────────────────────────────────────────────────────

  public static func isHelperInvocation(_ args: [String]) -> Bool { args.count >= 2 && args[1] == flag }

  /// Runs the overlay until stdin closes, which happens when the bridge exits.
  public static func helperMain() -> Never {
    let app = NSApplication.shared
    // An accessory app: no Dock icon, no menu bar, and it never becomes active,
    // so showing it cannot take focus from whatever the user is typing in.
    app.setActivationPolicy(.accessory)
    let window = OverlayWindow()
    let reader = Thread {
      while let line = readLine(strippingNewline: true) {
        let parts = line.split(separator: " ")
        if line == "done" {
          DispatchQueue.main.async { window.fade() }
        } else if parts.count == 2, let x = Double(parts[0]), let y = Double(parts[1]) {
          DispatchQueue.main.async { window.show(at: CGPoint(x: x, y: y)) }
        }
      }
      // stdin closed: the bridge is gone, and so should this be.
      DispatchQueue.main.async { NSApplication.shared.terminate(nil) }
    }
    reader.start()
    app.run()
    exit(0)
  }
}

/// The window the pointer is drawn in. Borderless, transparent, click-through,
/// above ordinary windows, and present on every Space so it can follow the app
/// being worked on rather than living on one desktop.
final class OverlayWindow: NSPanel {
  private let mark = CursorMark()
  private var idle: Timer?

  init() {
    super.init(contentRect: NSRect(x: 0, y: 0, width: AgentCursor.side, height: AgentCursor.side),
               styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
    isOpaque = false
    backgroundColor = .clear
    hasShadow = false
    // The whole point: it must never take a click meant for the app underneath,
    // and must never take focus from the user.
    ignoresMouseEvents = true
    level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.screenSaverWindow)) - 1)
    collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
    contentView = mark
    alphaValue = 0
  }

  override var canBecomeKey: Bool { false }
  override var canBecomeMain: Bool { false }

  /// `p` arrives in CG screen coordinates — origin at the top-left of the main
  /// display, y downwards. AppKit counts from the bottom-left of the whole
  /// desktop, so the y has to be turned over against the main display's height,
  /// not against whichever screen the point happens to land on.
  func show(at p: CGPoint) {
    let flipHeight = NSScreen.screens.first(where: { $0.frame.origin == .zero })?.frame.height
      ?? NSScreen.main?.frame.height ?? 0
    let half = AgentCursor.side / 2
    setFrameOrigin(NSPoint(x: p.x - half, y: flipHeight - p.y - half))
    if alphaValue < 1 { alphaValue = 1 }
    orderFrontRegardless()
    idle?.invalidate()
    idle = Timer.scheduledTimer(withTimeInterval: AgentCursor.idleSeconds, repeats: false) { [weak self] _ in
      self?.fade()
    }
  }

  func fade() {
    idle?.invalidate(); idle = nil
    NSAnimationContext.runAnimationGroup { ctx in
      ctx.duration = 0.35
      animator().alphaValue = 0
    } completionHandler: { [weak self] in
      if self?.alphaValue == 0 { self?.orderOut(nil) }
    }
  }
}

/// The drawing: a soft round glow with an arrow sitting in it, tip at the
/// centre so the mark points at the place being clicked rather than sitting
/// beside it.
final class CursorMark: NSView {
  override var isFlipped: Bool { false }

  override func draw(_ dirtyRect: NSRect) {
    guard let ctx = NSGraphicsContext.current?.cgContext else { return }
    let mid = CGPoint(x: bounds.midX, y: bounds.midY)

    // The glow. Two stops rather than one so the edge falls off to nothing
    // instead of ending on a visible circle.
    let accent = AgentCursor.accent
    let colours = [accent.withAlphaComponent(0.55).cgColor,
                   accent.withAlphaComponent(0.22).cgColor,
                   accent.withAlphaComponent(0).cgColor] as CFArray
    if let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colours,
                                 locations: [0, 0.45, 1]) {
      ctx.drawRadialGradient(gradient, startCenter: mid, startRadius: 0,
                             endCenter: mid, endRadius: AgentCursor.side / 2,
                             options: [])
    }

    // The arrow, in the usual pointer shape, its tip at the centre. Drawn in a
    // 20x20 box with y downwards, then turned over for AppKit.
    let arrow = NSBezierPath()
    let pts: [CGPoint] = [
      CGPoint(x: 0, y: 0), CGPoint(x: 0, y: 16.5), CGPoint(x: 4.3, y: 12.6),
      CGPoint(x: 7.1, y: 19), CGPoint(x: 9.8, y: 17.8), CGPoint(x: 7.1, y: 11.6),
      CGPoint(x: 12.4, y: 11.6),
    ]
    arrow.move(to: NSPoint(x: pts[0].x, y: -pts[0].y))
    for p in pts.dropFirst() { arrow.line(to: NSPoint(x: p.x, y: -p.y)) }
    arrow.close()
    arrow.lineJoinStyle = .round
    arrow.lineWidth = 1.6

    ctx.saveGState()
    ctx.translateBy(x: mid.x, y: mid.y)
    // A dark edge under the light fill, so the arrow reads on a pale window as
    // well as a dark one.
    NSColor.black.withAlphaComponent(0.55).setStroke()
    arrow.stroke()
    NSColor.white.withAlphaComponent(0.95).setFill()
    arrow.fill()
    ctx.restoreGState()
  }
}
