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
  /// The product's own colours, so a mark on screen reads as this app working
  /// rather than as an artefact of the OS.
  static let arrowColour = NSColor(srgbRed: 0xFF / 255.0, green: 0x77 / 255.0, blue: 0x64 / 255.0, alpha: 1)
  static let glowColour = NSColor(srgbRed: 0xF8 / 255.0, green: 0x57 / 255.0, blue: 0x3B / 255.0, alpha: 1)
  /// Wide enough for the glow to fall off to nothing inside the window.
  static let side: CGFloat = 132
  /// The arrow is drawn CENTRED in the glow, because that is what reads as one
  /// mark rather than an arrow with a halo hanging off it. But the tip is the
  /// part that means something — it is the place being clicked — so the whole
  /// window is shifted by this much to put the tip back on the point. Half the
  /// arrow's extent, in both directions.
  static let tipOffset: CGFloat = 8.75
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
    let off = AgentCursor.tipOffset
    setFrameOrigin(NSPoint(x: p.x - half + off, y: flipHeight - p.y - half - off))
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
    let glow = AgentCursor.glowColour
    let colours = [glow.withAlphaComponent(0.58).cgColor,
                   glow.withAlphaComponent(0.24).cgColor,
                   glow.withAlphaComponent(0).cgColor] as CFArray
    if let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colours,
                                 locations: [0, 0.45, 1]) {
      ctx.drawRadialGradient(gradient, startCenter: mid, startRadius: 0,
                             endCenter: mid, endRadius: AgentCursor.side * 0.42,
                             options: [])
    }

    // The arrow: an arrowhead with a concave back, drawn as an outline so the
    // glow shows through it rather than being covered up. Not the system
    // pointer silhouette — this should read as something an agent is doing,
    // not as the user's own cursor sitting somewhere unexpected.
    //
    // A 22pt shape in a box with y downwards, tip at the origin, then turned
    // over for AppKit. Tip, right wing, a notch pulled back toward the tip,
    // bottom wing, close.
    let arrow = NSBezierPath()
    let pts: [CGPoint] = [
      CGPoint(x: 0, y: 0),        // the tip, which is what sits on the point
      CGPoint(x: 17.5, y: 7),     // right wing
      CGPoint(x: 8, y: 8),        // the notch, back toward the tip
      CGPoint(x: 7, y: 17.5),     // bottom wing
    ]
    arrow.move(to: NSPoint(x: pts[0].x, y: -pts[0].y))
    for p in pts.dropFirst() { arrow.line(to: NSPoint(x: p.x, y: -p.y)) }
    arrow.close()
    arrow.lineJoinStyle = .round
    arrow.lineCapStyle = .round

    ctx.saveGState()
    // Centred: the arrow's own middle sits on the glow's middle. The window
    // placement puts the tip back on the click point.
    ctx.translateBy(x: mid.x - AgentCursor.tipOffset, y: mid.y + AgentCursor.tipOffset)
    // Light over dark: a white outline alone vanishes on a pale panel, a dark
    // one vanishes on a dark canvas. Drawn twice, it reads on both.
    arrow.lineWidth = 4.4
    NSColor.black.withAlphaComponent(0.38).setStroke()
    arrow.stroke()
    arrow.lineWidth = 2.1
    AgentCursor.arrowColour.setStroke()
    arrow.stroke()
    ctx.restoreGState()
  }
}
