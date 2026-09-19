// ProbeTarget: a native Mac app that records exactly how input reaches it.
//
// Built to answer one question about another agent's "own cursor": when it
// clicks, does the click arrive as a native mouse event, and if so where did
// it come from, and where was the real system pointer at that instant?
//
// Every hypothesis leaves a different trace here:
//   * the real pointer was moved      -> `pointer` samples reach the click point
//   * posted per process              -> targetPid is this app, tap log is silent
//   * posted to the global stream     -> tap log has it, pointer samples move
//   * an accessibility action         -> `axPress` row, and NO mouse rows
//   * nothing native at all           -> no rows here, but the web probe has some
//
// Writes one JSON object per line to ~/cua-probe/probe.jsonl.
import AppKit

// MARK: - log

let logURL: URL = {
  let dir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("cua-probe")
  try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
  return dir.appendingPathComponent("probe.jsonl")
}()
let logQueue = DispatchQueue(label: "probe.log")
/// Opened once, append-only: writes to it are atomic for lines this size.
let logFD: Int32 = open(logURL.path, O_WRONLY | O_APPEND | O_CREAT, 0o644)
let started = Date()

func log(_ src: String, _ fields: [String: Any]) {
  var row: [String: Any] = fields
  row["src"] = src
  row["t"] = Int(Date().timeIntervalSince(started) * 1000)
  row["wall"] = ISO8601DateFormatter().string(from: Date())
  logQueue.async {
    guard let data = try? JSONSerialization.data(withJSONObject: row, options: [.sortedKeys]),
          var line = String(data: data, encoding: .utf8) else { return }
    line += "\n"
    // Three processes share this file. Seek-then-write races and shreds lines;
    // one write to a descriptor opened O_APPEND does not.
    _ = line.withCString { write(logFD, $0, strlen($0)) }
  }
}

/// Where the real system pointer is, in screen coordinates with the origin at
/// the top left, which is the frame every other tool here reports.
func systemPointer() -> CGPoint {
  CGEvent(source: nil)?.location ?? .zero
}

// MARK: - the surface that records

final class ProbeView: NSView {
  var label: String
  init(frame: NSRect, label: String) { self.label = label; super.init(frame: frame) }
  required init?(coder: NSCoder) { fatalError() }
  override var acceptsFirstResponder: Bool { true }
  override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

  override func updateTrackingAreas() {
    super.updateTrackingAreas()
    trackingAreas.forEach(removeTrackingArea)
    addTrackingArea(NSTrackingArea(rect: bounds,
                                   options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                   owner: self, userInfo: nil))
  }

  override func draw(_ dirty: NSRect) {
    NSColor(calibratedWhite: 0.93, alpha: 1).setFill()
    dirty.fill()
    NSColor(calibratedWhite: 0.55, alpha: 1).setStroke()
    let path = NSBezierPath(rect: bounds.insetBy(dx: 1, dy: 1))
    path.lineWidth = 2
    path.stroke()
    let text = "\(label) — click or drag here" as NSString
    text.draw(at: NSPoint(x: 12, y: bounds.height - 24),
              withAttributes: [.font: NSFont.monospacedSystemFont(ofSize: 13, weight: .regular),
                               .foregroundColor: NSColor.darkGray])
    // Every point this view has been clicked at, so a drawn path is visible.
    NSColor.systemRed.setFill()
    for p in marks { NSBezierPath(ovalIn: NSRect(x: p.x - 2, y: p.y - 2, width: 4, height: 4)).fill() }
  }

  var marks: [NSPoint] = []

  private func record(_ event: NSEvent, _ kind: String) {
    let inWindow = event.locationInWindow
    let onScreen = window?.convertPoint(toScreen: inWindow) ?? .zero
    // AppKit's y grows upward from the bottom of the main display; everything
    // else here counts down from the top. Report both so nothing is guessed.
    let screenH = NSScreen.screens.first?.frame.height ?? 0
    let cg = CGPoint(x: onScreen.x, y: screenH - onScreen.y)
    var row: [String: Any] = [
      "kind": kind,
      "view": label,
      "inWindowX": Int(inWindow.x), "inWindowY": Int(inWindow.y),
      "screenCGX": Int(cg.x), "screenCGY": Int(cg.y),
      "windowNumber": event.windowNumber,
      "eventNumber": event.eventNumber,
      "clickCount": kind.hasPrefix("mouseDown") || kind.hasPrefix("mouseUp") ? event.clickCount : 0,
      "pressure": Double(event.pressure),
      "modifiers": event.modifierFlags.rawValue,
      "appActive": NSApp.isActive,
      "windowIsKey": window?.isKeyWindow ?? false,
      "windowOccluded": !(window?.occlusionState.contains(.visible) ?? true),
      // THE discriminator: where the real pointer was when this arrived.
      "systemPointerX": Int(systemPointer().x), "systemPointerY": Int(systemPointer().y),
    ]
    if let cge = event.cgEvent {
      row["srcPid"] = cge.getIntegerValueField(.eventSourceUnixProcessID)
      row["targetPid"] = cge.getIntegerValueField(.eventTargetUnixProcessID)
      row["srcStateID"] = cge.getIntegerValueField(.eventSourceStateID)
      row["srcUserData"] = cge.getIntegerValueField(.eventSourceUserData)
      row["windowUnderPointer"] = cge.getIntegerValueField(.mouseEventWindowUnderMousePointer)
      row["cgLocationX"] = Int(cge.location.x)
      row["cgLocationY"] = Int(cge.location.y)
    } else {
      row["cgEvent"] = "none (synthesised inside the app, not from the system event stream)"
    }
    log("native", row)
    if kind == "mouseDown" { marks.append(inWindow); needsDisplay = true }
  }

  override func mouseDown(with e: NSEvent) { record(e, "mouseDown") }
  override func mouseUp(with e: NSEvent) { record(e, "mouseUp") }
  override func mouseDragged(with e: NSEvent) { record(e, "mouseDragged") }
  override func rightMouseDown(with e: NSEvent) { record(e, "rightMouseDown") }
  override func otherMouseDown(with e: NSEvent) { record(e, "otherMouseDown") }
  override func scrollWheel(with e: NSEvent) { record(e, "scrollWheel") }
  // Moves are the noisiest and the most telling: if the agent moved the real
  // pointer, its journey shows up here.
  override func mouseMoved(with e: NSEvent) { record(e, "mouseMoved") }
}

/// A button that says so when it is pressed through accessibility rather than
/// clicked — the other main way an agent can act.
final class ProbeButton: NSButton {
  override func accessibilityPerformPress() -> Bool {
    log("ax", ["kind": "accessibilityPerformPress", "label": title,
               "systemPointerX": Int(systemPointer().x), "systemPointerY": Int(systemPointer().y),
               "appActive": NSApp.isActive])
    return super.accessibilityPerformPress()
  }
  override func setAccessibilityValue(_ value: Any?) {
    log("ax", ["kind": "setAccessibilityValue", "label": title, "value": String(describing: value)])
    super.setAccessibilityValue(value)
  }
}

final class ProbeField: NSTextField {
  override func setAccessibilityValue(_ value: Any?) {
    log("ax", ["kind": "setAccessibilityValue", "label": "field", "value": String(describing: value)])
    super.setAccessibilityValue(value)
  }
}

// MARK: - app

final class Delegate: NSObject, NSApplicationDelegate {
  var window: NSWindow!
  var lastPointer: CGPoint = .zero

  func applicationDidFinishLaunching(_ note: Notification) {
    let frame = NSRect(x: 120, y: 120, width: 900, height: 640)
    window = NSWindow(contentRect: frame,
                      styleMask: [.titled, .closable, .miniaturizable, .resizable],
                      backing: .buffered, defer: false)
    window.title = "ProbeTarget"
    window.isReleasedWhenClosed = false
    // Stage Manager parks a background app's window down to a thumbnail, which
    // would make every coordinate in this log meaningless. A floating window
    // that joins every Space is exempt, and stays reachable wherever the user
    // is working — which is the point of the rig.
    window.level = .floating
    // Follow whoever is looking. On a desktop of full-screen Spaces a normal
    // window sits on the Space it was born on, out of reach of both the user
    // and anything aiming at its coordinates; this brings it to the active
    // Space whenever the app is activated, which is what an agent does first.
    window.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]

    let content = NSView(frame: NSRect(origin: .zero, size: frame.size))
    let canvas = ProbeView(frame: NSRect(x: 20, y: 120, width: 860, height: 480), label: "CANVAS")
    canvas.autoresizingMask = [.width, .height]
    content.addSubview(canvas)

    for (i, name) in ["TARGET-A", "TARGET-B", "TARGET-C"].enumerated() {
      let b = ProbeButton(frame: NSRect(x: 20 + i * 150, y: 60, width: 130, height: 36))
      b.title = name
      b.bezelStyle = .rounded
      b.target = self
      b.action = #selector(pressed(_:))
      b.setAccessibilityLabel(name)
      content.addSubview(b)
    }

    let field = ProbeField(frame: NSRect(x: 480, y: 60, width: 400, height: 28))
    field.placeholderString = "TYPE-HERE"
    field.setAccessibilityLabel("TYPE-HERE")
    field.delegate = self
    content.addSubview(field)

    let hint = NSTextField(labelWithString: "Everything that reaches this window is written to ~/cua-probe/probe.jsonl")
    hint.frame = NSRect(x: 20, y: 20, width: 860, height: 20)
    hint.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
    hint.textColor = .secondaryLabelColor
    content.addSubview(hint)

    window.contentView = content
    window.makeKeyAndOrderFront(nil)

    log("state", ["kind": "launched", "pid": ProcessInfo.processInfo.processIdentifier,
                  "windowNumber": window.windowNumber,
                  "frameCG": ["x": Int(frame.minX), "y": Int((NSScreen.screens.first?.frame.height ?? 0) - frame.maxY),
                              "w": Int(frame.width), "h": Int(frame.height)],
                  "bundleId": Bundle.main.bundleIdentifier ?? "-"])

    // The real pointer, sampled often enough to see it travel to a click and
    // back. Only changes are written, plus a heartbeat, so the log stays small.
    Timer.scheduledTimer(withTimeInterval: 0.01, repeats: true) { [weak self] _ in
      guard let self else { return }
      let p = systemPointer()
      if abs(p.x - self.lastPointer.x) > 0.5 || abs(p.y - self.lastPointer.y) > 0.5 {
        self.lastPointer = p
        log("pointer", ["x": Int(p.x), "y": Int(p.y)])
      }
    }
    Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { _ in
      log("heartbeat", ["frontmost": NSWorkspace.shared.frontmostApplication?.localizedName ?? "?",
                        "appActive": NSApp.isActive,
                        "pointerX": Int(systemPointer().x), "pointerY": Int(systemPointer().y)])
    }

    for (name, sel) in [(NSApplication.didBecomeActiveNotification, "didBecomeActive"),
                        (NSApplication.didResignActiveNotification, "didResignActive")] {
      NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { _ in
        log("state", ["kind": sel, "frontmost": NSWorkspace.shared.frontmostApplication?.localizedName ?? "?"])
      }
    }
    NotificationCenter.default.addObserver(forName: NSWindow.didChangeOcclusionStateNotification, object: window, queue: .main) { [weak self] _ in
      log("state", ["kind": "occlusion", "visible": self?.window.occlusionState.contains(.visible) ?? false])
    }
  }

  @objc func pressed(_ sender: NSButton) {
    log("native", ["kind": "buttonAction", "label": sender.title,
                   "systemPointerX": Int(systemPointer().x), "systemPointerY": Int(systemPointer().y)])
  }
}

extension Delegate: NSTextFieldDelegate {
  func controlTextDidChange(_ obj: Notification) {
    guard let f = obj.object as? NSTextField else { return }
    log("native", ["kind": "textChanged", "value": f.stringValue])
  }
}

let app = NSApplication.shared
app.setActivationPolicy(.regular)
let delegate = Delegate()
app.delegate = delegate
app.run()
