import ApplicationServices
import CoreGraphics
import Darwin
import Foundation

/// Clicks and drags that reach a window nobody brought forward.
///
/// The ordinary route posts at screen coordinates, so the window has to be
/// where those coordinates are — which on a desktop of full-screen Spaces means
/// raising the app onto the user's screen first. This one addresses the window
/// instead: the event carries the target's pid and window id, and its point is
/// given in the WINDOW's coordinates rather than the screen's. The window stays
/// where it is, on whatever Space it is on, and the user's pointer never moves.
///
/// Measured 2026-09-14 against Figma 126.8.18 on Darwin 25.6, off-Space, with
/// another app frontmost: a click selects and deselects on the canvas, and a
/// held path carries a marquee selection. Five state changes, each confirmed by
/// reading the app back, pointer stationary throughout.
///
/// Two things make it work, and both are easy to get wrong:
///
/// 1. **The point must come from the accessibility frame, never from a
///    screenshot.** For a window on another Space the window server may hold
///    only a small skewed thumbnail of it — measured 138x157 for a window that
///    is really 1249x900, wrong by a factor of nine. Accessibility reports the
///    true frame, and this bridge already reads it, which is the whole reason
///    this route is worth having here rather than anywhere else.
/// 2. **A press must land off-screen first.** A browser engine gates synthetic
///    input on a user activation it has seen; a press at (-1,-1) satisfies that
///    gate while reaching no element, and a frame of quiet after it keeps the
///    two from being read as one run-on gesture.
///
/// The sequence and the record layout are ported from cua-driver
/// (MIT, Copyright (c) 2025 Cua AI, Inc.), `click_at_xy_chromium` and
/// `activate_without_raise`. The drag has no counterpart there — that driver
/// refuses background drags, because it takes its coordinates from a capture it
/// cannot trust and so cannot aim one. With the frame read from accessibility
/// the same events carry a drag perfectly well.
///
/// Every symbol is resolved with dlsym, so a macOS that drops one leaves the
/// bridge running with this route off rather than failing to launch.
enum BackgroundPointer {
  private typealias PostRecord = @convention(c) (UnsafeRawPointer, UnsafePointer<UInt8>) -> Int32
  private typealias FrontPSN = @convention(c) (UnsafeMutableRawPointer) -> Int32
  private typealias ProcForPid = @convention(c) (pid_t, UnsafeMutableRawPointer) -> Int32
  private typealias MainConn = @convention(c) () -> Int32
  private typealias WindowOwner = @convention(c) (Int32, CGWindowID, UnsafeMutablePointer<UInt32>) -> Int32
  private typealias ConnPSN = @convention(c) (UInt32, UnsafeMutableRawPointer) -> Int32
  private typealias PostToPid = @convention(c) (pid_t, UnsafeMutableRawPointer) -> Void
  private typealias SetIntField = @convention(c) (UnsafeMutableRawPointer, UInt32, Int64) -> Void
  private typealias SetWindowLoc = @convention(c) (UnsafeMutableRawPointer, Double, Double) -> Void

  private static func sym<T>(_ name: String, as: T.Type) -> T? {
    guard let p = dlsym(UnsafeMutableRawPointer(bitPattern: -2), name) else { return nil } // RTLD_DEFAULT
    return unsafeBitCast(p, to: T.self)
  }
  private static let postRecord = sym("SLPSPostEventRecordTo", as: PostRecord.self)
  private static let frontPSN = sym("_SLPSGetFrontProcess", as: FrontPSN.self)
  private static let procForPid = sym("GetProcessForPID", as: ProcForPid.self)
  private static let mainConn = sym("CGSMainConnectionID", as: MainConn.self)
  private static let windowOwner = sym("SLSGetWindowOwner", as: WindowOwner.self)
  private static let connPSN = sym("SLSGetConnectionPSN", as: ConnPSN.self)
  private static let postToPid = sym("SLEventPostToPid", as: PostToPid.self)
  private static let setIntField = sym("SLEventSetIntegerValueField", as: SetIntField.self)
  private static let setWindowLoc = sym("CGEventSetWindowLocation", as: SetWindowLoc.self)

  /// Every piece has to be present. A half-available route would deliver events
  /// the receiver cannot place, which is worse than not offering one.
  static var available: Bool {
    postRecord != nil && frontPSN != nil && postToPid != nil && setWindowLoc != nil
      && (procForPid != nil || (mainConn != nil && windowOwner != nil && connPSN != nil))
  }

  // Field numbers on a mouse event. Undocumented, and 0 is the surprising one:
  // it is nominally the event NUMBER and is used here to mark which part of the
  // gesture an event is, which is what lets the receiver tell the off-screen
  // primer apart from the press that follows it.
  private static let fPhase: UInt32 = 0
  private static let fClickState: UInt32 = 1
  private static let fButton: UInt32 = 3
  private static let fSubtype: UInt32 = 7
  private static let fTargetPid: UInt32 = 40
  private static let fWindow: UInt32 = 51
  private static let fWindowUnderPointer: UInt32 = 91
  private static let fWindowThatHandles: UInt32 = 92
  private static let fGesture: UInt32 = 58

  private static let phasePrimerDown: Int64 = 1
  private static let phaseMoveOrPrimerUp: Int64 = 2
  private static let phaseTarget: Int64 = 3

  /// The point a primer press lands on. Off every screen, so it can reach no
  /// element of any window while still counting as a press.
  private static let offScreen = CGPoint(x: -1, y: -1)

  private static let settleUs: UInt32 = 50_000    // let the app update its routing
  private static let afterMoveUs: UInt32 = 15_000
  private static let withinClickUs: UInt32 = 1_000
  private static let afterPrimerUs: UInt32 = 100_000  // a frame, so it is not run-on
  private static let dragStepUs: UInt32 = 16_000
  private static let betweenPairsUs: UInt32 = 80_000  // a double click is two pairs, not two clicks

  /// The target's process serial number, by the window's owning connection when
  /// that resolves and by pid otherwise. Only a PSN addresses a process here.
  private static func psn(pid: pid_t, windowId: CGWindowID) -> [UInt8]? {
    var out = [UInt8](repeating: 0, count: 8)
    let viaWindow: Bool = out.withUnsafeMutableBytes { raw in
      guard let mainConn, let windowOwner, let connPSN, windowId != 0 else { return false }
      var owner: UInt32 = 0
      guard windowOwner(mainConn(), windowId, &owner) == 0, owner != 0 else { return false }
      return connPSN(owner, raw.baseAddress!) == 0
    }
    if viaWindow { return out }
    guard let procForPid else { return nil }
    let ok: Bool = out.withUnsafeMutableBytes { raw in procForPid(pid, raw.baseAddress!) == 0 }
    return ok ? out : nil
  }

  /// Tell the app it is active without asking the window server to raise
  /// anything: one record saying the previous front has lost focus, one saying
  /// the target has gained it.
  ///
  /// Nothing here moves the window server's front process, and it is not meant
  /// to — checking `_SLPSGetFrontProcess` afterwards and finding it unchanged is
  /// the expected result, not a failure. Both posts returning 0 is the success
  /// condition. (Measured the hard way: a whole afternoon spent concluding this
  /// was broken, on the strength of watching the wrong thing.)
  @discardableResult
  static func activateWithoutRaise(pid: pid_t, windowId: CGWindowID) -> Bool {
    guard let postRecord, let frontPSN else { return false }
    var previous = [UInt8](repeating: 0, count: 8)
    let gotPrevious: Bool = previous.withUnsafeMutableBytes { frontPSN($0.baseAddress!) == 0 }
    guard gotPrevious, let target = psn(pid: pid, windowId: windowId) else { return false }

    // A 248-byte event record: a size at 0x04, a kind at 0x08, the window id
    // little-endian at 0x3C, and 0x8A saying whether this is a loss of focus
    // (2) or a gain (1). Everything else stays zero.
    var record = [UInt8](repeating: 0, count: 0xF8)
    record[0x04] = 0xF8
    record[0x08] = 0x0D
    record[0x3C] = UInt8(windowId & 0xFF)
    record[0x3D] = UInt8((windowId >> 8) & 0xFF)
    record[0x3E] = UInt8((windowId >> 16) & 0xFF)
    record[0x3F] = UInt8((windowId >> 24) & 0xFF)

    func post(_ to: [UInt8], kind: UInt8) -> Bool {
      record[0x8A] = kind
      return to.withUnsafeBytes { psnRaw in
        record.withUnsafeBufferPointer { rec in postRecord(psnRaw.baseAddress!, rec.baseAddress!) == 0 }
      }
    }
    let defocused = post(previous, kind: 0x02)
    let focused = post(target, kind: 0x01)
    return defocused && focused
  }

  /// One event of a gesture, addressed at a window rather than at the screen.
  private static func send(_ type: CGEventType, screen: CGPoint, local: CGPoint,
                           pid: pid_t, windowId: CGWindowID,
                           clickState: Int64, phase: Int64, gesture: Int64) {
    guard let event = CGEvent(mouseEventSource: nil, mouseType: type,
                              mouseCursorPosition: screen, mouseButton: .left) else { return }
    let raw = Unmanaged.passUnretained(event).toOpaque()
    func field(_ f: UInt32, _ v: Int64) {
      if let setIntField { setIntField(raw, f, v) }
      else { event.setIntegerValueField(CGEventField(rawValue: f)!, value: v) }
    }
    field(fPhase, phase)
    field(fClickState, clickState)
    field(fButton, 0)
    field(fSubtype, 3)
    field(fTargetPid, Int64(pid))
    if windowId != 0 {
      field(fWindow, Int64(windowId))
      field(fWindowUnderPointer, Int64(windowId))
      field(fWindowThatHandles, Int64(windowId))
    }
    field(fGesture, gesture)
    setWindowLoc?(raw, Double(local.x), Double(local.y))
    if let postToPid { postToPid(pid, raw) } else { event.postToPid(pid) }
  }

  private static func gestureId() -> Int64 { Int64(CFAbsoluteTimeGetCurrent() * 1e6) }

  /// The primer: a press and release where nothing can be hit, then a frame of
  /// quiet. Every gesture that follows counts as user-activated.
  private static func primer(pid: pid_t, windowId: CGWindowID, gesture: Int64) {
    send(.leftMouseDown, screen: offScreen, local: offScreen, pid: pid, windowId: windowId,
         clickState: 1, phase: phasePrimerDown, gesture: gesture)
    usleep(withinClickUs)
    send(.leftMouseUp, screen: offScreen, local: offScreen, pid: pid, windowId: windowId,
         clickState: 1, phase: phaseMoveOrPrimerUp, gesture: gesture)
    usleep(afterPrimerUs)
  }

  /// Tell the window the pointer has left. Without this the app goes on
  /// drawing a cursor wherever the gesture finished — it has been told where
  /// the pointer is and never told it moved away — which looks to the user
  /// like a second, frozen cursor sitting in their document. Measured
  /// 2026-09-14: one parked over the Effects row of a panel, at the exact
  /// point of the last click, until the window was touched by hand.
  ///
  /// Once per PATH, never between its points: a trace is many clicks that the
  /// app reads as one piece of drawing, and telling it the pointer left in the
  /// middle would be a worse bug than the cursor this fixes.
  static func park(pid: pid_t, windowId: CGWindowID) { park(pid: pid, windowId: windowId, gesture: gestureId()) }

  private static func park(pid: pid_t, windowId: CGWindowID, gesture: Int64) {
    send(.mouseMoved, screen: offScreen, local: offScreen, pid: pid, windowId: windowId,
         clickState: 0, phase: phaseMoveOrPrimerUp, gesture: gesture)
  }

  /// One click, or a double click, delivered to the window at `local` without
  /// raising it. A double click is not two clicks: the click STATE rises
  /// within one gesture, and an app can honour the second and ignore a pair of
  /// firsts.
  static func click(pid: pid_t, windowId: CGWindowID, screen: CGPoint, local: CGPoint, clicks: Int = 1) {
    activateWithoutRaise(pid: pid, windowId: windowId)
    usleep(settleUs)
    let gesture = gestureId()
    send(.mouseMoved, screen: screen, local: local, pid: pid, windowId: windowId,
         clickState: 0, phase: phaseMoveOrPrimerUp, gesture: gesture)
    usleep(afterMoveUs)
    primer(pid: pid, windowId: windowId, gesture: gesture)
    for pair in 1...max(1, min(clicks, 2)) {
      if pair > 1 { usleep(betweenPairsUs) }
      send(.leftMouseDown, screen: screen, local: local, pid: pid, windowId: windowId,
           clickState: Int64(pair), phase: phaseTarget, gesture: gesture)
      usleep(withinClickUs)
      send(.leftMouseUp, screen: screen, local: local, pid: pid, windowId: windowId,
           clickState: Int64(pair), phase: phaseTarget, gesture: gesture)
    }
  }

  /// A held path: pressed at the first point, dragged through the rest,
  /// released at the last. `path` is screen point and window-local point for
  /// each step, in order.
  static func drag(pid: pid_t, windowId: CGWindowID, path: [(screen: CGPoint, local: CGPoint)]) {
    guard let first = path.first, let last = path.last, path.count > 1 else { return }
    activateWithoutRaise(pid: pid, windowId: windowId)
    usleep(settleUs)
    let gesture = gestureId()
    send(.mouseMoved, screen: first.screen, local: first.local, pid: pid, windowId: windowId,
         clickState: 0, phase: phaseMoveOrPrimerUp, gesture: gesture)
    usleep(afterMoveUs)
    primer(pid: pid, windowId: windowId, gesture: gesture)
    send(.leftMouseDown, screen: first.screen, local: first.local, pid: pid, windowId: windowId,
         clickState: 1, phase: phaseTarget, gesture: gesture)
    usleep(dragStepUs)
    for step in path.dropFirst() {
      send(.leftMouseDragged, screen: step.screen, local: step.local, pid: pid, windowId: windowId,
           clickState: 1, phase: phaseTarget, gesture: gesture)
      usleep(dragStepUs)
    }
    send(.leftMouseUp, screen: last.screen, local: last.local, pid: pid, windowId: windowId,
         clickState: 1, phase: phaseTarget, gesture: gesture)
    park(pid: pid, windowId: windowId, gesture: gesture)
  }
}
