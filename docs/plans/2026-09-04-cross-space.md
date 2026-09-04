# Cross-Space Windows Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Read and act on an app's windows from any Space, so the agent never has to raise the target app and the user stays in Unbiased.

**Architecture:** A per-pid `WindowMap` inside `LiveBackend` finds window elements the public `AXWindows` attribute cannot list, by scanning the app's element-id space through the private `_AXUIElementCreateWithRemoteToken` and mapping hits to window ids with `_AXUIElementGetWindow`. Those elements are fed into `LiveSource`'s root children and into `windows()`, so `tree`, `find`, and every action verb work unchanged. A startup self-check proves the mechanism on this machine; if it fails, `crossSpace` is false and the bridge behaves exactly as today. unbiased-app reads the flag from `hello` and gates its raise-recovery machinery off.

**Tech Stack:** Swift 5.9 (SwiftPM, `swift build` / `swift run unbiased-ax-tests`), ApplicationServices + AppKit, three private HIServices symbols resolved with `dlsym`. TypeScript (Electron main process, `node --test` via tsx) on the app side.

**Read first:** `docs/plans/2026-09-04-cross-space-design.md` (the validated design and every measured number) and `scripts/probe/README.md` (the token layout and the probes). The bridge repo has no XCTest: tests are an executable, `make test` runs them, and `Sources/unbiased-ax-tests/Harness.swift` is the entire assertion API (`test`, `expect`, `expectEqual`). `AXBridge` has no unit tests by design — verification there is the runtime self-check plus manual probes.

**Two repositories.** Tasks 1–8 are in this worktree (`unbiased-ax`). Tasks 9–12 are in the unbiased-app worktree the dev build runs from: `/Users/naveen/Projects/Work/unbiased-app/.claude/worktrees/agitated-wilbur-0ab621` (branch `fix/ax-launch-scroll-verbs`). Every path below is relative to whichever repo the task names.

---

## Part A — unbiased-ax

### Task 1: `crossSpace` on the wire, `onSpace` on a window

Pure layer. Adds the flag to `hello` and the per-window marker, with a stub in the live backend so the whole package still builds.

**Files:**
- Modify: `Sources/AXModel/Protocol.swift:10-24` (WindowInfo) and `:68-71` (Backend)
- Modify: `Sources/AXModel/Dispatcher.swift:36-37` (hello)
- Modify: `Sources/AXBridge/LiveBackend.swift:15-17` (stub)
- Modify: `Sources/unbiased-ax-tests/DispatcherTests.swift:5-26` (FakeBackend)
- Create: `Sources/unbiased-ax-tests/CrossSpaceTests.swift`
- Modify: `Sources/unbiased-ax-tests/main.swift:12`

**Step 1: Write the failing tests**

Create `Sources/unbiased-ax-tests/CrossSpaceTests.swift`:

```swift
import Foundation
import AXModel

/// AXWindows lists only the current Space. With the private remote-token path
/// the bridge reaches windows anywhere, and the model must never be told to
/// raise again. These pin what the model sees in both worlds.
func runCrossSpaceTests() {
  print("Across Spaces")
  func call(_ d: Dispatcher, _ json: String) -> String { d.handle(line: json) }

  test("hello says whether the bridge reads across Spaces") {
    let b = FakeBackend()
    try expect(call(Dispatcher(backend: b), #"{"id":1,"method":"hello"}"#).contains(#""crossSpace":false"#))
    b.crossSpaceOn = true
    try expect(call(Dispatcher(backend: b), #"{"id":2,"method":"hello"}"#).contains(#""crossSpace":true"#))
  }

  test("an off-Space window is listed and marked, not hidden") {
    let b = FakeBackend(); b.crossSpaceOn = true; b.hideWindows = true
    let out = call(Dispatcher(backend: b), #"{"id":3,"method":"windows","params":{"app":"Brave Browser"}}"#)
    try expect(out.contains("YouTube - Brave"), "the window is there to be read: \(out)")
    try expect(out.contains("[other Space]"), "and the model can see it is elsewhere: \(out)")
    try expect(out.contains(#""onSpace":false"#), out)
  }
}
```

Register it in `Sources/unbiased-ax-tests/main.swift` after `runDesktopReachTests()`:

```swift
runDesktopReachTests()
runCrossSpaceTests()
runSettleTests()
```

**Step 2: Run the tests to verify they fail**

Run: `swift build 2>&1 | grep error: ; swift run unbiased-ax-tests 2>&1 | tail -5`
Expected: the build fails with `value of type 'FakeBackend' has no member 'crossSpaceOn'` (the tests do not compile yet — that is the failing state for a compiled language).

**Step 3: Add `onSpace` to `WindowInfo` and `crossSpace()` to `Backend`**

In `Sources/AXModel/Protocol.swift`, replace lines 10–24 with:

```swift
public struct WindowInfo: Codable, Equatable {
  public var id: Int, title: String, x: Int, y: Int, width: Int, height: Int, minimized: Bool, focused: Bool
  /// False for a window on another Space. Such a window IS in the tree and
  /// takes actions like any other; the flag only tells the model where it is.
  public var onSpace: Bool
  public init(id: Int, title: String, x: Int, y: Int, width: Int, height: Int, minimized: Bool, focused: Bool, onSpace: Bool = true) {
    self.id = id; self.title = title; self.x = x; self.y = y; self.width = width; self.height = height
    self.minimized = minimized; self.focused = focused; self.onSpace = onSpace
  }
  /// `1 "YouTube - Brave" @0,0 1200x800 [focused]` — the model reads windows the
  /// same way it reads elements.
  public var line: String {
    var parts = ["\(id) \"\(title)\" @\(x),\(y) \(width)x\(height)"]
    if focused { parts.append("[focused]") }
    if minimized { parts.append("[minimized]") }
    if !onSpace { parts.append("[other Space]") }
    return parts.joined(separator: " ")
  }
}
```

In the same file, replace lines 68–71 (the start of `Backend`) with:

```swift
/// What the live adapter provides. Everything the dispatcher needs, nothing more.
public protocol Backend: AnyObject {
  func isTrusted() -> Bool
  /// Whether windows on another Space are in the tree. True only when the live
  /// adapter has proved the private remote-token path works on this machine;
  /// false means today's behaviour, raise hints included.
  func crossSpace() -> Bool
  func apps() -> [AppInfo]
  func windows(app: String) throws -> [WindowInfo]
```

**Step 4: Report it from `hello`**

In `Sources/AXModel/Dispatcher.swift`, replace line 37 with:

```swift
      return ["name": "unbiased-ax", "protocolVersion": protocolVersion, "trusted": backend.isTrusted(), "crossSpace": backend.crossSpace()]
```

**Step 5: Stub the live backend and teach the fake**

In `Sources/AXBridge/LiveBackend.swift`, after line 17 (`public func isTrusted()`), add:

```swift
  public func crossSpace() -> Bool { false }   // replaced in Task 5
```

In `Sources/unbiased-ax-tests/DispatcherTests.swift`, inside `FakeBackend`:

Replace line 11 (`var hideWindows = false`) with:

```swift
  var hideWindows = false
  /// Models the live adapter having proved the remote-token path. With it on,
  /// a "hidden" window is still listed, flagged as on another Space.
  var crossSpaceOn = false
```

Replace lines 18–19 (`func isTrusted()`) with:

```swift
  func isTrusted() -> Bool { trusted }
  func crossSpace() -> Bool { crossSpaceOn }
```

Replace the `windows(app:)` body (lines 24–27) with:

```swift
  func windows(app: String) throws -> [WindowInfo] {
    guard app == "Brave Browser" else { throw BridgeError.noSuchApp(app) }
    let win = WindowInfo(id: 1, title: "YouTube - Brave", x: 0, y: 0, width: 1200, height: 800, minimized: false, focused: true, onSpace: !hideWindows)
    if hideWindows && !crossSpaceOn { return [] }
    return [win]
  }
```

**Step 6: Run the tests to verify they pass**

Run: `make test 2>&1 | tail -8`
Expected: `Across Spaces` group shows two ✔ lines; final line `72 passed, 0 failed`.

**Step 7: Commit**

```bash
git add Sources/AXModel/Protocol.swift Sources/AXModel/Dispatcher.swift Sources/AXBridge/LiveBackend.swift Sources/unbiased-ax-tests/DispatcherTests.swift Sources/unbiased-ax-tests/CrossSpaceTests.swift Sources/unbiased-ax-tests/main.swift
git commit -m "feat(model): hello reports crossSpace, and a window says when it is on another Space"
```

---

### Task 2: No raise hint when the bridge reads across Spaces

Pure layer. `annotateSpaces` keeps reporting `offscreen` but stops telling the model to raise once off-Space windows are in the tree.

**Files:**
- Modify: `Sources/AXModel/Dispatcher.swift:134-151`
- Modify: `Sources/unbiased-ax-tests/CrossSpaceTests.swift`

**Step 1: Write the failing tests**

Append inside `runCrossSpaceTests()` in `Sources/unbiased-ax-tests/CrossSpaceTests.swift`, before the closing brace:

```swift
  test("a read across Spaces carries no raise hint, and still counts what is elsewhere") {
    // The whole point: the model must never be sent to raise for a window it
    // can already read. The count stays so a UI can say where the work is.
    let b = FakeBackend(); b.crossSpaceOn = true; b.hideWindows = true; b.offscreen = 1
    for method in ["tree", "windows", "find"] {
      let out = call(Dispatcher(backend: b), #"{"id":4,"method":"\#(method)","params":{"app":"Brave Browser","title":"OK"}}"#)
      try expect(out.contains(#""offscreen":1"#), "\(method) must still report the count: \(out)")
      try expect(!out.contains("hint"), "\(method) must not hint when the window is readable: \(out)")
      try expect(!out.lowercased().contains("raise"), "\(method) must never mention raising: \(out)")
    }
  }

  test("with cross-Space off, the hint is exactly what it was") {
    let b = FakeBackend(); b.hideWindows = true; b.offscreen = 1
    let out = call(Dispatcher(backend: b), #"{"id":5,"method":"tree","params":{"app":"Brave Browser"}}"#)
    try expect(out.contains("call raise for this app first"), out)
  }
```

**Step 2: Run the tests to verify they fail**

Run: `make test 2>&1 | grep -A2 '✖'`
Expected: `✖ a read across Spaces carries no raise hint...` with `tree must not hint when the window is readable`.

**Step 3: Gate the hint**

In `Sources/AXModel/Dispatcher.swift`, replace lines 134–151 with:

```swift
  /// Off-Space windows, and what to do about them. Without the remote-token
  /// path AXWindows lists only the current Space, so "no windows" and "windows
  /// elsewhere" look identical in a tree; the hint is the only thing that tells
  /// them apart, and its advice differs by whether anything readable is HERE:
  /// with a window on this Space the model raised for no reason and took the
  /// user's screen; with none, no amount of reading finds the window — a model
  /// spent six minutes proving that, and another lost the task to a shell.
  /// With the remote-token path proved, every window is in the tree and there
  /// is nothing to advise: the count stays, the hint goes.
  private func annotateSpaces(_ out: inout [String: Any], app: String, windowsHere: Int) throws {
    let off = try backend.offscreenWindows(app: app)
    out["offscreen"] = off
    guard off > 0, !backend.crossSpace() else { return }
    if windowsHere == 0 {
      out["hint"] = "This app's \(off) window(s) are all on another Space or hidden. They are NOT in the tree and cannot be read or acted on from here: call raise for this app first, then read again."
    } else {
      out["hint"] = "\(off) further window(s) are on another Space or hidden. The window(s) here are readable — work with those; do not raise."
    }
  }
```

**Step 4: Run the tests to verify they pass**

Run: `make test 2>&1 | tail -3`
Expected: `74 passed, 0 failed`.

**Step 5: Commit**

```bash
git add Sources/AXModel/Dispatcher.swift Sources/unbiased-ax-tests/CrossSpaceTests.swift
git commit -m "feat(model): no raise hint once off-Space windows are in the tree"
```

---

### Task 3: `RemoteToken` — the private symbols, behind `dlsym`

Live layer, no unit tests (see the design). Everything private lives in this one file.

**Files:**
- Create: `Sources/AXBridge/RemoteToken.swift`

**Step 1: Create the file**

```swift
import AppKit
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
  static let tag: UInt32 = 0x636f636f // 'coco'

  /// The element with this internal id, or nil if the symbol is missing. The
  /// element may still be invalid — the first attribute read says (-25202).
  static func element(pid: pid_t, elementId: UInt32) -> AXUIElement? {
    guard let create else { return nil }
    var d = Data(count: 20)
    d.withUnsafeMutableBytes { (b: UnsafeMutableRawBufferPointer) in
      b.storeBytes(of: UInt32(bitPattern: pid), toByteOffset: 0, as: UInt32.self)
      b.storeBytes(of: tag, toByteOffset: 8, as: UInt32.self)
      b.storeBytes(of: elementId, toByteOffset: 12, as: UInt32.self)
    }
    return create(d as CFData)?.takeRetainedValue()
  }

  /// The window-server id behind a window element.
  static func windowId(of el: AXUIElement) -> CGWindowID? {
    guard let windowOf else { return nil }
    var w: CGWindowID = 0
    return windowOf(el, &w) == .success ? w : nil
  }

  /// The internal element id inside an existing element's token, or nil when
  /// the token is not the 'coco' shape this code understands.
  static func elementId(of el: AXUIElement) -> UInt32? {
    guard let tokenOf, let t = tokenOf(el)?.takeRetainedValue() else { return nil }
    let d = t as Data
    guard d.count >= 16 else { return nil }
    let seen = d.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 8, as: UInt32.self) }
    guard seen == tag else { return nil }
    return d.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 12, as: UInt32.self) }
  }
}
```

**Step 2: Build**

Run: `swift build 2>&1 | grep -E 'error|warning: var' ; echo "exit ${PIPESTATUS[0]}"`
Expected: no `error:` lines. (An unused-symbol warning is fine; Task 4 uses everything.)

**Step 3: Commit**

```bash
git add Sources/AXBridge/RemoteToken.swift
git commit -m "feat(bridge): RemoteToken — the private remote-token symbols, resolved with dlsym"
```

---

### Task 4: `WindowMap` — wid → window element, found by scanning

Live layer. The cache and the scan. Also the self-check that proves the mechanism at startup.

**Files:**
- Create: `Sources/AXBridge/WindowMap.swift`

**Step 1: Create the file**

```swift
import AppKit
import ApplicationServices
import CoreGraphics
import Foundation

/// The windows of one process wherever they are: wid -> window element. Built
/// by scanning the app's element-id space through RemoteToken and keeping the
/// AXWindow hits — the mechanism AltTab ships as windowsByBruteForce. A cache:
/// rescanned only when the window server lists a wid this map has not settled.
struct WindowMap {
  /// Real windows only. Fullscreen toolbar panes are AXWindow with subrole
  /// AXUnknown and one element each; the system's per-app 3840x30 strips have
  /// no AX element at all. Neither is a window a model should be shown.
  static let realSubroles: Set<String> = ["AXStandardWindow", "AXDialog"]
  /// About a second at the measured 16µs per miss. Window elements are made
  /// early (ids 45–209 observed), but a window opened late in a long Chromium
  /// session has a high id; this bounds the hunt. Paid once per unsettled wid.
  static let scanCap: UInt32 = 65_536

  private(set) var byWid: [CGWindowID: AXElement] = [:]
  /// Every wid the window server listed that a scan has already settled,
  /// mapped or not. What a full scan did not find will not appear later.
  private var settled: Set<CGWindowID> = []

  var elements: [AXElement] { Array(byWid.values) }

  /// Layer-0 windows the window server lists for the pid, on any Space.
  static func serverWindows(pid: pid_t) -> Set<CGWindowID> {
    let list = (CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID) as? [[String: Any]]) ?? []
    var out = Set<CGWindowID>()
    for w in list where (w[kCGWindowOwnerPID as String] as? Int32) == pid && ((w[kCGWindowLayer as String] as? Int) ?? 1) == 0 {
      if let n = w[kCGWindowNumber as String] as? Int { out.insert(CGWindowID(n)) }
    }
    return out
  }

  /// Bring the map up to date with the window server. Free when nothing
  /// changed; one scan when a wid appeared that is not settled yet.
  mutating func refresh(pid: pid_t) {
    let live = Self.serverWindows(pid: pid)
    byWid = byWid.filter { live.contains($0.key) }
    settled.formIntersection(live)
    var missing = live.subtracting(settled)
    guard !missing.isEmpty else { return }
    let started = Date()
    var id: UInt32 = 0
    while id < Self.scanCap, !missing.isEmpty {
      defer { id += 1 }
      guard let el = RemoteToken.element(pid: pid, elementId: id),
            Self.attr(el, kAXRoleAttribute) == "AXWindow",
            let wid = RemoteToken.windowId(of: el), missing.contains(wid) else { continue }
      if Self.realSubroles.contains(Self.attr(el, kAXSubroleAttribute) ?? "") { byWid[wid] = AXElement(ref: el) }
      missing.remove(wid)
    }
    if LiveSource.debug {
      let ms = Int(Date().timeIntervalSince(started) * 1000)
      FileHandle.standardError.write("[ax] window scan pid \(pid): \(id) ids in \(ms)ms, \(byWid.count) real window(s), \(missing.count) wid(s) with no element\n".data(using: .utf8)!)
    }
    settled = live
  }

  private static func attr(_ el: AXUIElement, _ a: String) -> String? {
    var v: CFTypeRef?
    return AXUIElementCopyAttributeValue(el, a as CFString, &v) == .success ? v as? String : nil
  }

  /// Prove the mechanism on THIS machine before relying on it. An app with
  /// windows must yield a real window whose id the window server lists, and
  /// when that app has a public AXWindows element, a token rebuilt from scratch
  /// must be CFEqual to it. Anything less: cross-Space stays off and the bridge
  /// behaves exactly as before. Never guess with a private API that has stopped
  /// round-tripping.
  static func selfCheck() -> Bool {
    guard RemoteToken.available, AXIsProcessTrusted() else { return false }
    var candidates = NSWorkspace.shared.runningApplications.filter { $0.activationPolicy == .regular }
    if let f = NSWorkspace.shared.frontmostApplication, let i = candidates.firstIndex(of: f) { candidates.swapAt(0, i) }
    for a in candidates.prefix(3) {
      let pid = a.processIdentifier
      guard !serverWindows(pid: pid).isEmpty else { continue }
      let root = AXUIElementCreateApplication(pid)
      AXUIElementSetMessagingTimeout(root, 1.0)
      var v: CFTypeRef?
      if AXUIElementCopyAttributeValue(root, kAXWindowsAttribute as CFString, &v) == .success, let pub = axElements(v).first {
        guard let id = RemoteToken.elementId(of: pub), let rebuilt = RemoteToken.element(pid: pid, elementId: id), CFEqual(rebuilt, pub) else {
          if LiveSource.debug { FileHandle.standardError.write("[ax] cross-Space self-check: token round-trip failed on \(a.localizedName ?? "?")\n".data(using: .utf8)!) }
          return false
        }
      }
      var map = WindowMap()
      map.refresh(pid: pid)
      if !map.byWid.isEmpty {
        if LiveSource.debug { FileHandle.standardError.write("[ax] cross-Space self-check: ok via \(a.localizedName ?? "?")\n".data(using: .utf8)!) }
        return true
      }
    }
    return false
  }
}
```

**Step 2: Build**

Run: `swift build 2>&1 | grep -E 'error' ; echo "exit ${PIPESTATUS[0]}"`
Expected: no `error:` lines.

**Step 3: Commit**

```bash
git add Sources/AXBridge/WindowMap.swift
git commit -m "feat(bridge): WindowMap — every window of a process, found by scanning element ids, with a startup self-check"
```

---

### Task 5: Wire the map into `LiveBackend` and `LiveSource`

Live layer. `windows`, `offscreenWindows`, `snapshot` and `launch` learn about off-Space windows; `crossSpace()` reports the self-check.

**Files:**
- Modify: `Sources/AXBridge/LiveSource.swift:8-13` and `:78-90`
- Modify: `Sources/AXBridge/LiveBackend.swift:9-18`, `:42-77`, `:102-127`, `:215-260`

**Step 1: Let `LiveSource` take extra window roots**

In `Sources/AXBridge/LiveSource.swift`, replace lines 8–13 with:

```swift
struct LiveSource: ElementSource {
  typealias Node = AXElement
  /// The application element this source was made for. Chromium apps list
  /// only their menu bar under the root's AXChildren; windows live under
  /// AXWindows. Measured on Brave: tree came back as the menu bar alone.
  var appRoot: AXElement? = nil
  /// Windows AXWindows cannot list — on another Space — reached through
  /// RemoteToken. They hang off the root like any other window.
  var extraWindows: [AXElement] = []
```

Replace lines 83–88 (the `if let root = appRoot` block inside `children(of:)`) with:

```swift
    if let root = appRoot, node == root {
      var w: CFTypeRef?
      if AXUIElementCopyAttributeValue(node.ref, kAXWindowsAttribute as CFString, &w) == .success {
        for win in axElements(w).map(AXElement.init) where !kids.contains(win) { kids.append(win) }
      }
      for win in extraWindows where !kids.contains(win) { kids.append(win) }
    }
```

**Step 2: The self-check result and the maps**

In `Sources/AXBridge/LiveBackend.swift`, replace lines 9–18 (class header through `crossSpace()` stub) with:

```swift
public final class LiveBackend: Backend {
  private var registries: [pid_t: IdRegistry] = [:]
  /// id -> element from the last snapshot (or windows call), so act/setValue
  /// resolve an id the model saw to the element it meant.
  private var elements: [pid_t: [Int: AXElement]] = [:]
  /// Every window of each process, on any Space. Only consulted when the
  /// self-check passed; see WindowMap.selfCheck.
  private var windowMaps: [pid_t: WindowMap] = [:]
  private let crossSpaceEnabled: Bool

  public init() {
    crossSpaceEnabled = WindowMap.selfCheck()
  }

  public func isTrusted() -> Bool { AXIsProcessTrusted() }
  public func crossSpace() -> Bool { crossSpaceEnabled }
```

**Step 3: Public windows plus off-Space windows**

Replace lines 42–77 (`windows(app:)` and `offscreenWindows(app:)`) with:

```swift
  /// The windows AXWindows lists — the current Space — as elements.
  private func publicWindows(_ a: NSRunningApplication) throws -> [AXElement] {
    let root = appElement(a)
    var v: CFTypeRef?
    let err = AXUIElementCopyAttributeValue(root.ref, kAXWindowsAttribute as CFString, &v)
    if LiveSource.debug {
      FileHandle.standardError.write("[ax] AXWindows for \(a.localizedName ?? "?"): AXError \(err.rawValue), \(axElements(v).count) element(s)\n".data(using: .utf8)!)
    }
    if err == .cannotComplete { throw BridgeError.timeout("\(a.localizedName ?? "the app") did not list its windows") }
    guard err == .success else { return [] }
    return axElements(v).map(AXElement.init)
  }

  /// Real windows on other Spaces: what the window server lists that AXWindows
  /// does not. Empty unless the self-check passed. `appElement` has already
  /// set the app-wide messaging timeout, so the scan cannot hang either.
  private func offSpaceWindows(_ a: NSRunningApplication, here: [AXElement]) -> [AXElement] {
    guard crossSpaceEnabled else { return [] }
    var map = windowMaps[a.processIdentifier] ?? WindowMap()
    map.refresh(pid: a.processIdentifier)
    windowMaps[a.processIdentifier] = map
    return map.elements.filter { !here.contains($0) }
  }

  public func windows(app: String) throws -> [WindowInfo] {
    let a = try resolve(app)
    let here = try publicWindows(a)
    let elsewhere = offSpaceWindows(a, here: here)
    let src = LiveSource()
    var reg = registries[a.processIdentifier] ?? IdRegistry()
    var out: [WindowInfo] = []
    for (el, onSpace) in here.map { ($0, true) } + elsewhere.map { ($0, false) } {
      guard let at = src.attributes(of: el) else { continue }
      var minimized: CFTypeRef?
      AXUIElementCopyAttributeValue(el.ref, kAXMinimizedAttribute as CFString, &minimized)
      let id = reg.id(for: el)
      elements[a.processIdentifier, default: [:]][id] = el
      out.append(WindowInfo(id: id, title: at.title ?? "", x: at.x, y: at.y, width: at.width, height: at.height,
                            minimized: (minimized as? Bool) ?? false, focused: at.focused, onSpace: onSpace))
    }
    registries[a.processIdentifier] = reg
    return out
  }

  /// With cross-Space on: real windows not on this Space, which ARE in the
  /// tree. Without it: everything the window server lists that is not on
  /// screen — the only signal there was, inflated by system strips.
  public func offscreenWindows(app: String) throws -> Int {
    let a = try resolve(app)
    if crossSpaceEnabled {
      return offSpaceWindows(a, here: try publicWindows(a)).count
    }
    let list = (CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID) as? [[String: Any]]) ?? []
    return list.filter {
      ($0[kCGWindowOwnerPID as String] as? Int32) == a.processIdentifier
        && (($0[kCGWindowLayer as String] as? Int) ?? 1) == 0
        && !(($0[kCGWindowIsOnscreen as String] as? Bool) ?? false)
    }.count
  }
```

**Step 4: Snapshot the off-Space windows too**

In `snapshot(app:options:)`, replace the two lines that build the snapshot (originally 120–121, `var reg = ...` and `let snap = Snapshot.build(...)`) with:

```swift
    var reg = registries[a.processIdentifier] ?? IdRegistry()
    let extra = offSpaceWindows(a, here: (try? publicWindows(a)) ?? [])
    let snap = Snapshot.build(root: root, source: LiveSource(appRoot: root, extraWindows: extra), registry: &reg, options: options)
```

**Step 5: Launch in the background when the tree can see everywhere**

In `launch(app:timeout:)`, replace the comment block and the `proc.arguments` line (originally 230–236) with:

```swift
    // Foreground only when the tree is blind to other Spaces: a background
    // launch (-g) leaves the new window wherever the app puts it, and without
    // the remote-token path that window is NOT in the tree — measured: a
    // 1-element tree and an off-Space hint. With cross-Space on, -g is the
    // right call: the window is readable wherever it lands and the user keeps
    // their screen, which is the whole point.
    proc.arguments = (crossSpaceEnabled ? ["-g"] : []) + [looksLikeBundleId ? "-b" : "-a", app]
```

Also amend the wait-loop comment (originally 243–248) so it no longer claims "on THIS Space" — replace it with:

```swift
    // READABLE, not merely running. `windows` includes off-Space windows when
    // cross-Space is on, so "readable" means "anywhere"; without it, it means
    // "on this Space", and activating a window that lives elsewhere means
    // macOS has a Space switch to finish first.
```

**Step 6: Build and run the unit tests (they must be unaffected)**

Run: `make test 2>&1 | tail -3`
Expected: `74 passed, 0 failed`.

**Step 7: Verify live, from a trusted terminal, with Brave on another Space**

Run (each line is one request; the bridge reads stdin):

```bash
printf '%s\n' '{"id":1,"method":"hello"}' '{"id":2,"method":"windows","params":{"app":"Brave"}}' '{"id":3,"method":"find","params":{"app":"Brave","role":"text field","title":"address"}}' | UNBIASED_AX_DEBUG=1 .build/debug/unbiased-ax
```

Expected:
- line 1 contains `"crossSpace":true`
- stderr shows `[ax] cross-Space self-check: ok via ...` and `[ax] window scan pid ...: N ids in Nms, 1 real window(s)`
- line 2 lists Brave's window with `[other Space]` and `"offscreen":1`, and **no** `hint`
- line 3 has `"count":1` or more with `text field "Address and search bar"`

If `crossSpace` is false, read the `[ax] cross-Space self-check:` stderr line — it names what failed.

**Step 8: Commit**

```bash
git add Sources/AXBridge/LiveSource.swift Sources/AXBridge/LiveBackend.swift
git commit -m "feat(bridge): windows on another Space are in the tree — read, found and acted on without a raise"
```

---

### Task 6: `key` and `scroll` on an off-Space window — verify, don't assume

Manual verification only; `scroll` is the one verb that uses screen coordinates. Requires the user's approval for the actions, and Brave on another Space with a scrollable page.

**Files:** none unless a fix is needed.

**Step 1: Read the tree and pick targets**

```bash
printf '%s\n' '{"id":1,"method":"tree","params":{"app":"Brave","web":true}}' | .build/debug/unbiased-ax | head -c 4000
```

Note the id of the address bar (`text field "Address and search bar"`) and of the web area or a scrollable group.

**Step 2: `key` with a focus target**

Ask the user, then:

```bash
printf '%s\n' '{"id":1,"method":"tree","params":{"app":"Brave"}}' '{"id":2,"method":"key","params":{"app":"Brave","key":"escape","id":<ADDRESS_BAR_ID>}}' | .build/debug/unbiased-ax | tail -1
```

Expected: `"ok":true` and a diff; the frontmost app on the user's screen unchanged (check with `{"method":"apps"}` before and after — the same app must be `frontmost`).

**Step 3: `scroll` off-Space**

Ask the user, then:

```bash
printf '%s\n' '{"id":1,"method":"tree","params":{"app":"Brave","web":true}}' '{"id":2,"method":"scroll","params":{"app":"Brave","id":<WEB_AREA_ID>,"dy":-3}}' | .build/debug/unbiased-ax | tail -1
```

Expected: `"ok":true`. If the diff is `(no changes)` and a later `tree` shows nothing scrolled, the coordinate-based pointer move does not reach an off-Space window; record that in `docs/plans/2026-09-04-cross-space-design.md` under Risks and have the dispatcher return `action_failed` with "scroll cannot reach a window on another Space; raise it first" when `crossSpace` is on and the target window is not on-Space. Do not fix silently.

**Step 4: Record the result**

Append one line per verb to the design document's Risks section stating what was observed, and commit:

```bash
git add docs/plans/2026-09-04-cross-space-design.md
git commit -m "docs: measured key and scroll on an off-Space window"
```

---

### Task 7: The protocol document tells the truth

`docs/PROTOCOL.md` last changed four commits before `launch`/`scroll` shipped and still carries three claims the code contradicts. Replace it whole.

**Files:**
- Modify: `docs/PROTOCOL.md` (whole file)
- Modify: `README.md:105-113` (Layout)

**Step 1: Replace `docs/PROTOCOL.md`**

```markdown
# unbiased-ax protocol (version 1)

Newline-delimited JSON over stdio. One request per line, one response per line,
in order. Blank lines are skipped. EOF on stdin is a clean shutdown. Nothing
else is ever written to stdout; diagnostics go to stderr.

    {"id":1,"method":"tree","params":{"app":"Brave","interactive":true}}
    {"id":1,"result":{"tree":"1 standard window \"…\" {raise}\n2   toolbar\n…","count":41,"truncated":false,"offscreen":0}}

Three rules the model must know:

1. **Ids are stable per app until the element disappears.** `act 17` two turns
   later hits the same element or is refused with `no_such_element` — never a
   different element. An element absent from one snapshot and back in the next
   gets a new id.
2. **`tree` returns a diff after the first call** for an app, unless
   `"full":true`. `~` changed, `+` added, `- removed: 2-4, 9`. `(no changes)`
   when nothing moved. `find`, `launch` and every action reset the baseline.
3. **Every action waits for the app to react** before reporting: at least 0.6s,
   at most 1.5s. An action that changes nothing pays the full 1.5s.

## Spaces

`hello` reports `crossSpace`. When true, windows on another Space are in the
tree and take actions like any other; `windows` marks them `[other Space]` and
`offscreen` counts them. Nothing needs raising to be read. When false — the
private path failed its self-check on this machine — only the current Space is
readable, and reads carry a `hint` saying whether to `raise`.

## Methods

| method | params | result |
|---|---|---|
| `hello` | — | `{name, protocolVersion, trusted, crossSpace}` — works without Accessibility |
| `apps` | — | `{apps:[{pid,name,bundleId,frontmost}]}` — works without Accessibility |
| `windows` | `app` | `{windows:[{id,title,x,y,width,height,minimized,focused,onSpace}], text, offscreen, hint?}` — one line per window |
| `tree` | `app`, `depth?`(14), `maxElements?`(1500), `interactive?`, `web?` (Chromium page content, opt-in, sticky for that process), `geometry?`, `full?` | `{tree|diff, count, truncated, offscreen, hint?}` |
| `find` | `app`, `role?` (exact), `title?` (substring, also matches value), plus the `tree` options | `{matches:[lines], count, offscreen, hint?}` — a search, not a dump |
| `act` | `app`, `id`, `action` (`press`, `confirm` — commits a text field —, `raise`, `show menu`, `focus`, or any action shown in braces), `keepFront?` (default false) | `{ok, diff}` |
| `setValue` | `app`, `id`, `value`, `keepFront?` (default false) | `{ok, diff}` — focuses the element first |
| `key` | `app`, `key` (`return`, `tab`, `escape`, `space`, `delete`, `up`, `down`, `left`, `right`), `id?` (focus this element first) | `{ok, diff}` — a real key event posted to the app's pid |
| `scroll` | `app`, `id`, `dx?`, `dy?` (one non-zero; negative `dy` scrolls down) | `{ok, diff}` — real wheel events at the element's midpoint |
| `raise` | `app`, `window?` | `{ok, diff}` — brings the app forward from any Space. Takes the user's screen: only when the user should see the app |
| `launch` | `app`, `timeout?`(15), plus the `tree` options | `{ok, alreadyRunning, tree, count, offscreen, hint?}` — opens the app (in the background when `crossSpace`) and waits until it is readable |
| `icon` | `app` | `{png}` — the app's icon, base64 PNG, 64px |

`app` is a name ("Brave Browser"), a name prefix ("Brave"), a bundle id, or a pid.
`keepFront` restores whatever app was in front before an action; off by
default because restoring after every action undid the one raise that made an
app readable, and the next read raised again.

## Element lines

    3     text field "Address and search bar" = youtube.com/ [focused] {press}

`id`, indentation by depth, role, `"title"`, `= value`, flags (`[focused]`
`[selected]` `[disabled]`), `{actions}`, and with `geometry:true` `@x,y wxh`.
Titles and values are clipped at 120 characters.

## Errors

    {"id":1,"error":{"code":"not_trusted","message":"…"}}

| code | meaning |
|---|---|
| `bad_request` | the line was not a JSON object with a `method` (no `id` in the response) |
| `bad_params` | a required param is missing or invalid; the message names it |
| `unknown_method` | the message lists the methods |
| `not_trusted` | Accessibility not granted to this process; the message says where |
| `no_such_app` | nothing running matches; call `apps` |
| `no_such_element` | the id is not in this app's last snapshot; call `tree` |
| `no_such_window` | call `windows` |
| `action_failed` | the app refused; supported actions are the ones in braces |
| `timeout` | the app did not answer within the 1s messaging timeout |
| `launch_failed` | `open` could not find the app; do not retry |
| `internal` | a bug in the bridge; the message is the Swift error |
```

**Step 2: Mention the probes in the README layout**

In `README.md`, in the `## Layout` block, add after the `docs/plans/` line:

```
    scripts/probe/            the probes that established the cross-Space path — see docs/plans/2026-09-04-cross-space-design.md
```

**Step 3: Commit**

```bash
git add docs/PROTOCOL.md README.md
git commit -m "docs: protocol tells the truth — crossSpace, onSpace, launch, scroll, and the keepFront default"
```

---

### Task 8: Bundle and hand off

**Step 1: Build the release bundle**

Run: `make bundle 2>&1 | tail -3`
Expected: `dist/unbiased-ax (…), dist/manifest.json`.

**Step 2: Confirm the bundle self-checks from the app's identity**

The dev app resolves the bridge from a sibling checkout (`resolveAxDir`), so it will pick up `dist/` from whichever `unbiased-ax` directory is beside the app worktree. Confirm which one:

```bash
ls -la /Users/naveen/Projects/Work/unbiased-app/.claude/worktrees/agitated-wilbur-0ab621/../../../unbiased-ax/dist 2>/dev/null || echo "the app resolves a different checkout — set UNBIASED_AX_DIR to this worktree's dist when launching the dev app"
```

**Step 3: Commit nothing** — `dist/` is gitignored. Proceed to Part B.

---

## Part B — unbiased-app (`/Users/naveen/Projects/Work/unbiased-app/.claude/worktrees/agitated-wilbur-0ab621`)

Run tests with: `node --import tsx --test src/main/ax-bridge.test.ts`
Typecheck with: `npm run typecheck`

### Task 9: `AxClient` learns `crossSpace` from `hello`

**Files:**
- Modify: `src/main/ax-bridge.ts:333-372`
- Modify: `src/main/ax-bridge.test.ts:60-92`

**Step 1: Write the failing test**

In `src/main/ax-bridge.test.ts`, in `fakeBridge()` (line 70), change the hello reply to include the flag:

```js
  if (method === "hello") return console.log(JSON.stringify({ id, result: { name: "unbiased-ax", protocolVersion: 1, trusted: true, crossSpace: true } }));
```

Replace the handshake test (lines 84–92) with:

```ts
test("start performs the handshake and reports trust and cross-Space", async () => {
  const m = fakeBridge();
  assert.ok(m && !("error" in m));
  const c = new AxClient(m);
  const hello = await c.start();
  assert.equal(hello.trusted, true);
  assert.equal(hello.crossSpace, true, "a bridge that reads across Spaces says so, and the app must know");
  assert.equal(c.crossSpace, true);
  assert.equal(c.alive, true);
  c.stop();
});
```

**Step 2: Run the test to verify it fails**

Run: `node --import tsx --test src/main/ax-bridge.test.ts 2>&1 | grep -B2 -A6 'reports trust and cross-Space'`
Expected: `not ok` with `hello.crossSpace` being `undefined`.

**Step 3: Carry the flag**

In `src/main/ax-bridge.ts`, replace line 338 (`trusted = false;`) with:

```ts
  trusted = false;
  /** Whether the bridge reads windows on other Spaces. False means today's
   *  behaviour: reads carry raise hints and the app keeps its raise recovery. */
  crossSpace = false;
```

Replace the `start()` signature (line 345) with:

```ts
  async start(): Promise<{ trusted: boolean; crossSpace: boolean; version: string }> {
```

Replace lines 369–370 (`this.trusted = ...; return { ... }`) with:

```ts
    this.trusted = hello.trusted === true;
    this.crossSpace = hello.crossSpace === true;
    return { trusted: this.trusted, crossSpace: this.crossSpace, version: this.manifest.version };
```

In `src/main/index.ts`, replace line 2191 (the `axLog(\`bridge ...\`)` line) with:

```ts
    axLog(`bridge ${hello.version} ready (${hello.trusted ? "trusted" : "NOT trusted: Accessibility not granted"}, cross-Space ${hello.crossSpace ? "on" : "off"})`);
```

**Step 4: Run the tests and typecheck**

Run: `node --import tsx --test src/main/ax-bridge.test.ts 2>&1 | tail -6 && npm run typecheck 2>&1 | tail -2`
Expected: all tests `ok`; typecheck clean.

**Step 5: Commit**

```bash
git add src/main/ax-bridge.ts src/main/ax-bridge.test.ts src/main/index.ts
git commit -m "feat(ax): the client learns from hello whether the bridge reads across Spaces"
```

---

### Task 10: The raise recovery stands down when the bridge can see everywhere

**Files:**
- Modify: `src/main/ax-bridge.ts:317-325`
- Modify: `src/main/ax-bridge.test.ts:268-276`
- Modify: `src/main/index.ts:2117-2126` and `:2254-2258`

**Step 1: Write the failing test**

Replace the recovery test (lines 268–276) in `src/main/ax-bridge.test.ts` with:

```ts
test("a read that comes back empty retries once, but only for an app we raised before, and never across Spaces", () => {
  assert.equal(shouldRecoverRaise({ windowsHere: 0, offscreen: 12, raisedBefore: true, crossSpace: false }), true);
  assert.equal(shouldRecoverRaise({ windowsHere: 0, offscreen: 12, raisedBefore: false, crossSpace: false }), false,
    "never raise an app the model has not already chosen to bring forward");
  assert.equal(shouldRecoverRaise({ windowsHere: 2, offscreen: 12, raisedBefore: true, crossSpace: false }), false,
    "windows are here; nothing to recover");
  assert.equal(shouldRecoverRaise({ windowsHere: 0, offscreen: 0, raisedBefore: true, crossSpace: false }), false,
    "the app has no windows at all — raising will not conjure one");
  assert.equal(shouldRecoverRaise({ windowsHere: 0, offscreen: 12, raisedBefore: true, crossSpace: true }), false,
    "with cross-Space on the window is readable where it is; measured 9 automatic raises in 4 minutes before this");
});
```

**Step 2: Run the test to verify it fails**

Run: `node --import tsx --test src/main/ax-bridge.test.ts 2>&1 | grep -A8 'never across Spaces'`
Expected: `not ok` — the last assertion gets `true`. (Typecheck also fails on the extra property; that is expected until Step 3.)

**Step 3: Gate the helper and both call paths**

In `src/main/ax-bridge.ts`, replace lines 317–325 with:

```ts
/** Whether a read that found nothing should raise and try again by itself.
 *  Only for an app this conversation already raised: the user consented to
 *  that app coming forward once, and it drifting back off-Space between two
 *  actions is not a new decision — it is the same one, undone. Measured: one
 *  working run spent a third of its calls re-asking for a raise it had
 *  already been given.
 *  Never when the bridge reads across Spaces: the window is in the tree where
 *  it is, and "0 windows here" is no longer a problem to recover from.
 *  Measured before that: 9 automatic raises in four minutes, each one undoing
 *  the user's return to their own Space. */
export function shouldRecoverRaise(s: { windowsHere: number; offscreen: number; raisedBefore: boolean; crossSpace: boolean }): boolean {
  return !s.crossSpace && s.raisedBefore && s.windowsHere === 0 && s.offscreen > 0;
}
```

In `src/main/index.ts`, replace `reassertRaise` (lines 2117–2126) with:

```ts
/** Put back a raise that an approval card undid. Cheap when nothing was
 *  raised, and silent on failure: this is a convenience, not a step. Nothing
 *  to put back when the bridge reads across Spaces — the card did not take
 *  anything the work needed. */
async function reassertRaise(root: string): Promise<void> {
  const appName = axRaised.get(root);
  if (!appName || !ax?.alive || ax.crossSpace) return;
  try {
    axLog(`raise ${appName} (re-assert after an approval card)`);
    await ax.request("raise", { app: appName }, 3_000);
  } catch {
    // the app may have quit; the next read will say so plainly
  }
}
```

In the `computer_app_state` handler, replace lines 2254–2258 (the `shouldRecoverRaise({...})` call) with:

```ts
        if (shouldRecoverRaise({
          windowsHere: ((w.windows as unknown[]) ?? []).length,
          offscreen: Number(w.offscreen ?? 0),
          raisedBefore: axRaised.get(root) === appName,
          crossSpace: ax.crossSpace,
        })) {
```

Also in that handler, the head line `"windows: none on this Space"` is now wrong when `crossSpace` is on and the app truly has no windows. Replace the `head` construction (lines 2265–2268) with:

```ts
        const head = [
          windowsText ? `windows:\n${windowsText}` : (ax.crossSpace ? "windows: none" : "windows: none on this Space"),
          typeof w.hint === "string" ? w.hint : "",
        ].filter(Boolean).join("\n");
```

**Step 4: Run the tests and typecheck**

Run: `node --import tsx --test src/main/ax-bridge.test.ts 2>&1 | tail -6 && npm run typecheck 2>&1 | tail -2`
Expected: all `ok`; typecheck clean.

**Step 5: Commit**

```bash
git add src/main/ax-bridge.ts src/main/ax-bridge.test.ts src/main/index.ts
git commit -m "fix(ax): the raise recovery stands down when the bridge reads across Spaces"
```

---

### Task 11: The tool descriptions stop sending the model to raise

`AX_TOOLS` must stay a literal `const AX_TOOLS = [ … ];` — `ax-bridge.test.ts:363-368` slices the source text of that block to check tool names. So the descriptions are rewritten at the one place the list is handed to the model.

**Files:**
- Modify: `src/main/ax-bridge.ts` (append)
- Modify: `src/main/ax-bridge.test.ts` (append)
- Modify: `src/main/index.ts:1265-1300` (three descriptions) and `:1602` (spread)

**Step 1: Write the failing test**

Append to `src/main/ax-bridge.test.ts`:

```ts
// ── Space guidance in the tool descriptions ────────────────────────────────
// With cross-Space on, telling the model to raise before reading is telling it
// to take the user's screen for nothing.

test("with cross-Space on, no description sends the model to raise", () => {
  const raise = { name: "computer_raise", description: RAISE_DESCRIPTION };
  const state = { name: "computer_app_state", description: "Read stuff. " + APP_STATE_SPACE_SENTENCE + "More." };
  const launch = { name: "computer_launch", description: "Open it. " + LAUNCH_FRONT_SENTENCE };
  const other = { name: "computer_apps", description: "List running apps." };

  for (const t of [raise, state, launch, other]) assert.deepEqual(withSpaceGuidance(t, false), t, "off: byte-identical to today");

  assert.ok(!withSpaceGuidance(raise, true).description.includes("exactly one case"));
  assert.ok(withSpaceGuidance(raise, true).description.includes("only when the user asked to SEE"));
  assert.ok(!withSpaceGuidance(state, true).description.includes("call computer_raise"));
  assert.ok(withSpaceGuidance(state, true).description.includes("never raise"));
  assert.ok(!withSpaceGuidance(launch, true).description.includes("brings the app to the front"));
  assert.deepEqual(withSpaceGuidance(other, true), other, "tools with nothing to say about Spaces are untouched");
});
```

Add the four names to the import on line 9 of the test file: `RAISE_DESCRIPTION, APP_STATE_SPACE_SENTENCE, LAUNCH_FRONT_SENTENCE, withSpaceGuidance`.

**Step 2: Run the test to verify it fails**

Run: `node --import tsx --test src/main/ax-bridge.test.ts 2>&1 | grep -B2 -A4 'sends the model to raise'`
Expected: fails to import (`withSpaceGuidance` is not exported).

**Step 3: The sentences and the rewrite**

Append to `src/main/ax-bridge.ts`:

```ts
/** The parts of the tool descriptions that are about Spaces, and what they
 *  become once the bridge reads across them. Kept here, not in index.ts, so
 *  they are tested; index.ts builds its literal AX_TOOLS from the "off"
 *  versions and rewrites at the point the list is handed to the model. */
export const APP_STATE_SPACE_SENTENCE =
  "If the result says every window is on another Space, the app is NOT in the tree — call computer_raise once, then read again. If windows ARE listed, work with them and do not raise. ";
export const APP_STATE_SPACE_SENTENCE_CROSS =
  "Windows on another Space are in the tree and work like any other — never raise to read or act; a window line marked [other Space] is still fully usable. ";
export const RAISE_DESCRIPTION =
  "Bring an app to the front, switching Spaces if its windows are elsewhere. This TAKES OVER the user's screen, so use it in exactly one case: computer_app_state reported that every window of the app is on another Space, which means the app is not in the tree and cannot be read or acted on until it is raised. Never raise to read or press an app whose windows are already listed. This always requires explicit user approval.";
export const RAISE_DESCRIPTION_CROSS =
  "Bring an app to the front, switching Spaces if its windows are elsewhere. This TAKES OVER the user's screen. Reading and acting never need it — every window is in the tree wherever it is — so use it only when the user asked to SEE the app. This always requires explicit user approval.";
export const LAUNCH_FRONT_SENTENCE =
  "This brings the app to the front, which is what opening an app means.";
export const LAUNCH_FRONT_SENTENCE_CROSS =
  "It opens in the background: the tree is readable without bringing the app forward, and the user keeps their screen.";

export function withSpaceGuidance<T extends { name: string; description: string }>(tool: T, crossSpace: boolean): T {
  if (!crossSpace) return tool;
  switch (tool.name) {
    case "computer_raise":
      return { ...tool, description: RAISE_DESCRIPTION_CROSS };
    case "computer_app_state":
      return { ...tool, description: tool.description.replace(APP_STATE_SPACE_SENTENCE, APP_STATE_SPACE_SENTENCE_CROSS) };
    case "computer_launch":
      return { ...tool, description: tool.description.replace(LAUNCH_FRONT_SENTENCE, LAUNCH_FRONT_SENTENCE_CROSS) };
    default:
      return tool;
  }
}
```

In `src/main/index.ts`, make the literal use the constants so the replace is exact. Add the four names to the existing import from `./ax-bridge` (the import that already brings in `shouldRecoverRaise`). Then:

- Line 1273 (the `"If the result says every window is on another Space, ... do not raise. "` fragment of `computer_app_state`'s description): replace that string literal, keeping the surrounding `+` operators, with `APP_STATE_SPACE_SENTENCE +` followed by the `"Pass query to search for one control by title instead of reading everything. "` fragment as its own string.
- Line 1293 (`computer_raise` description): replace the whole string literal with `RAISE_DESCRIPTION`.
- Line 1301 (the second fragment of `computer_launch`'s description): replace `"Harmless if the app is already running — it says so and reads it. This brings the app to the front, which is what opening an app means."` with `"Harmless if the app is already running — it says so and reads it. " + LAUNCH_FRONT_SENTENCE`.
- Line 1602: replace `...(ax?.alive ? AX_TOOLS : []),` with `...(ax?.alive ? AX_TOOLS.map((t) => withSpaceGuidance(t, ax!.crossSpace)) : []),`.

**Step 4: Run the tests and typecheck**

Run: `node --import tsx --test src/main/ax-bridge.test.ts 2>&1 | tail -6 && npm run typecheck 2>&1 | tail -2`
Expected: all `ok` — including the existing "every tool the app declares to the model is routed" test, which slices the literal and must still find every `name:`; typecheck clean.

**Step 5: Commit**

```bash
git add src/main/ax-bridge.ts src/main/ax-bridge.test.ts src/main/index.ts
git commit -m "fix(ax): with cross-Space on, no tool description sends the model to raise"
```

---

### Task 12: Acceptance — the Maps task, measured

The number that started this: 10 raises in four minutes. The target is 0.

**Step 1: Point the dev app at the new bridge and start it with diagnostics**

From the app worktree:

```bash
UNBIASED_AX_DEBUG=1 UNBIASED_AX_DIR=/Users/naveen/Projects/Work/unbiased-ax/.claude/worktrees/repo-comprehension-579cb2/dist npm run dev
```

Confirm in `/tmp/unbiased-ax-diag.log`: `bridge <version> ready (trusted, cross-Space on)`. If it says `off`, the self-check failed under the app's identity — read the bridge's stderr (`[ax] cross-Space self-check: ...`) in the app console before going further.

**Step 2: Run the task from Unbiased's Space, with Maps on another Space**

In a Computer-mode conversation: *Open Apple Maps and calculate the distance, route, etc. from my current location to Planet Fitness (S State Street).* Stay on Unbiased's Space for the whole run.

**Step 3: Count**

```bash
grep -c 'raise ' /tmp/unbiased-ax-diag.log
```

Expected: `0` new raise lines for this run (compare timestamps against the run's start). The user's screen never left Unbiased.

**Step 4: The README's headline task**

Same, with Brave on another Space: *play a YouTube video in my open Brave tab.* Expected: no raise, and the window title changes to the video in `windows`.

**Step 5: Record**

Append the two measured results to the "Measured" table in `docs/plans/2026-09-04-cross-space-design.md` in the bridge repo, and commit:

```bash
git add docs/plans/2026-09-04-cross-space-design.md
git commit -m "docs: cross-Space measured end to end — zero raises on the Maps and YouTube tasks"
```

If either task raised, do not tune blindly: find the log line's reason (`the model asked`, `auto:`, `re-assert`) — each names exactly one code path in Tasks 10–11.
