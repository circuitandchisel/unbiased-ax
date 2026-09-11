// recorder: watches the SYSTEM event stream from outside the target app.
//
// The pair of facts that separates the hypotheses is "did the app receive it"
// (ProbeTarget answers that) and "did the rest of the system see it" (this
// does). An event posted to one process never reaches a tap; an event posted
// to the screen always does, and drags the pointer with it.
//
// Listen only: it never modifies, consumes or delays anything.
import AppKit

let logURL: URL = {
  let dir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("cua-probe")
  try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
  return dir.appendingPathComponent("probe.jsonl")
}()
let started = Date()
let logQueue = DispatchQueue(label: "probe.recorder.log")
/// Opened once, append-only: writes to it are atomic for lines this size.
let logFD: Int32 = open(logURL.path, O_WRONLY | O_APPEND | O_CREAT, 0o644)

func log(_ src: String, _ fields: [String: Any]) {
  var row = fields
  row["src"] = src
  row["t"] = Int(Date().timeIntervalSince(started) * 1000)
  row["wall"] = ISO8601DateFormatter().string(from: Date())
  logQueue.async {
    guard let d = try? JSONSerialization.data(withJSONObject: row, options: [.sortedKeys]),
          var s = String(data: d, encoding: .utf8) else { return }
    s += "\n"
    // See ProbeTarget: one atomic append, because three processes share this file.
    _ = s.withCString { write(logFD, $0, strlen($0)) }
  }
}

let mask: CGEventMask =
  (1 << CGEventType.leftMouseDown.rawValue) | (1 << CGEventType.leftMouseUp.rawValue) |
  (1 << CGEventType.leftMouseDragged.rawValue) | (1 << CGEventType.rightMouseDown.rawValue) |
  (1 << CGEventType.mouseMoved.rawValue) | (1 << CGEventType.keyDown.rawValue) |
  (1 << CGEventType.scrollWheel.rawValue)

func name(_ t: CGEventType) -> String {
  switch t {
  case .leftMouseDown: return "leftMouseDown"
  case .leftMouseUp: return "leftMouseUp"
  case .leftMouseDragged: return "leftMouseDragged"
  case .rightMouseDown: return "rightMouseDown"
  case .mouseMoved: return "mouseMoved"
  case .keyDown: return "keyDown"
  case .scrollWheel: return "scrollWheel"
  default: return "type\(t.rawValue)"
  }
}

func callback(proxy: CGEventTapProxy, type: CGEventType, event: CGEvent, ctx: UnsafeMutableRawPointer?) -> Unmanaged<CGEvent>? {
  // Moves are only interesting as a trail, and there are thousands; keep them
  // but strip them to nothing but a position.
  if type == .mouseMoved {
    log("tapMove", ["x": Int(event.location.x), "y": Int(event.location.y),
                    "srcPid": event.getIntegerValueField(.eventSourceUnixProcessID)])
    return Unmanaged.passUnretained(event)
  }
  log("tap", [
    "kind": name(type),
    "x": Int(event.location.x), "y": Int(event.location.y),
    "srcPid": event.getIntegerValueField(.eventSourceUnixProcessID),
    "targetPid": event.getIntegerValueField(.eventTargetUnixProcessID),
    "srcStateID": event.getIntegerValueField(.eventSourceStateID),
    "srcUserData": event.getIntegerValueField(.eventSourceUserData),
    "windowUnderPointer": event.getIntegerValueField(.mouseEventWindowUnderMousePointer),
    "clickState": event.getIntegerValueField(.mouseEventClickState),
    "frontmost": NSWorkspace.shared.frontmostApplication?.localizedName ?? "?",
  ])
  return Unmanaged.passUnretained(event)
}

let wantHID = CommandLine.arguments.contains("--hid")
let place: CGEventTapLocation = wantHID ? .cghidEventTap : .cgAnnotatedSessionEventTap
guard let tap = CGEvent.tapCreate(tap: place, place: .headInsertEventTap, options: .listenOnly,
                                  eventsOfInterest: mask, callback: callback, userInfo: nil) else {
  log("state", ["kind": "tapFailed", "hint": "grant Accessibility (and Input Monitoring) to the terminal running this"])
  print("could not create the tap — Accessibility / Input Monitoring not granted")
  exit(1)
}
CFRunLoopAddSource(CFRunLoopGetCurrent(), CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0), .commonModes)
CGEvent.tapEnable(tap: tap, enable: true)
log("state", ["kind": "recorderStarted", "tap": wantHID ? "HID" : "annotatedSession",
              "pid": ProcessInfo.processInfo.processIdentifier])
print("recorder listening (\(wantHID ? "HID" : "annotated session")) -> \(logURL.path)")

NSWorkspace.shared.notificationCenter.addObserver(
  forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { note in
  let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
  log("state", ["kind": "appActivated", "app": app?.localizedName ?? "?", "pid": app?.processIdentifier ?? -1])
}

// Windows that appear over the probe (an agent's own cursor overlay would be
// one): sampled rather than watched, because there is no notification for
// another process's windows.
var known = Set<Int>()
// The first sweeps record what is already on screen without reporting it;
// otherwise every menu bar extra shows up as a "new" window at startup.
let seedUntil = Date().addingTimeInterval(3)
Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { _ in
  guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else { return }
  for w in list {
    let num = (w[kCGWindowNumber as String] as? Int) ?? 0
    guard !known.contains(num) else { continue }
    known.insert(num)
    let owner = (w[kCGWindowOwnerName as String] as? String) ?? "?"
    // Only report newcomers that are not ours and sit above ordinary windows,
    // which is where an overlay cursor would live.
    let layer = (w[kCGWindowLayer as String] as? Int) ?? 0
    // The system's own furniture reappears constantly with new numbers; an
    // agent's overlay will not be one of these.
    let furniture = ["ProbeTarget", "Dock", "Control Center", "Window Server", "Notification Center",
                     "Spotlight", "SystemUIServer", "loginwindow", "Wallpaper", "universalaccessd"]
    if !furniture.contains(owner), layer != 0, Date() > seedUntil {
      log("window", ["kind": "appeared", "owner": owner, "layer": layer,
                     "bounds": w[kCGWindowBounds as String] ?? [:], "number": num])
    }
  }
}

RunLoop.current.run()
