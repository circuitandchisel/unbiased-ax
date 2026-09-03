# unbiased-ax Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** A small, fast macOS helper that gives an agent the *structure* of what is on screen — apps, windows, and each app's accessibility element tree as compact text with stable ids and diffs — plus the ability to act on those elements, so the agent stops guessing pixel coordinates from screenshots.

**Architecture:** One long-running Swift process speaking newline-delimited JSON over stdio (the same contract unbiased-app already uses for its engine and its learning sidecar). A pure, framework-free core (`AXModel`) does snapshotting, stable ids, pruning, formatting and diffing against an `ElementSource` protocol, so every hard part is unit-tested with a fake tree. A thin live adapter (`AXBridge`) implements that protocol over `AXUIElement` and `NSWorkspace`. The executable wires the two. Performance comes from four deliberate choices: one IPC per element (`AXUIElementCopyMultipleAttributeValues`), a messaging timeout so an unresponsive app can never hang a call, pruning of zero-size and untitled container nodes with child hoisting, and returning a **diff** rather than a full tree after the first snapshot of an app.

**Tech Stack:** Swift 6.3 toolchain in Swift 5 language mode (AXUIElement is not Sendable; strict concurrency buys nothing here), SwiftPM, ApplicationServices + AppKit. **No test framework** — CommandLineTools ships neither XCTest nor Swift Testing (verified 2026-09-03), so tests are a plain executable target with a 40-line harness. `codesign` ad-hoc with a stable identifier so the Accessibility grant survives rebuilds.

**Measured motivation (2026-09-03):** the same task — "play a YouTube video in my open Brave tab" — took unbiased-app 27 tool calls and 6.7 minutes (11 screenshots of a desktop that did not contain Brave, which was on another Space) and took Codex 7 calls and 67 seconds by reading Brave's accessibility tree as text, finding the selected tab, setting the URL bar, and confirming playback from the window title "Audio playing". This repo builds the piece that makes the second path possible.

---

## Conventions for every task

- Run tests with `swift run unbiased-ax-tests`. It exits non-zero on any failure. There is no other test runner.
- Build with `swift build`. The live adapter needs Accessibility permission to *do* anything, but it must always *build* and always answer `hello`.
- Commit after every task with the message given. Commit messages go through a file (`git commit -F`), never inline — backticks in inline messages have eaten words before.
- The pure core (`Sources/AXModel`) must never `import AppKit` or `import ApplicationServices`. If a task tempts you to, the abstraction is wrong; stop and fix the abstraction.
- "Interactive roles" means: button, checkbox, radio button, pop up button, menu button, menu item, menu bar item, text field, text area, search field, combo box, slider, link, tab, tab group's children, table row, outline row, cell, disclosure triangle, incrementor, scroll bar, toolbar, window. Everything else is structure.

---

### Task 0: Scaffold, harness, first green test

**Files:**
- Create: `Package.swift`
- Create: `.gitignore`
- Create: `README.md`
- Create: `Sources/AXModel/AXModel.swift`
- Create: `Sources/AXBridge/AXBridge.swift`
- Create: `Sources/unbiased-ax/main.swift`
- Create: `Sources/unbiased-ax-tests/Harness.swift`
- Create: `Sources/unbiased-ax-tests/main.swift`

**Step 1: Package manifest**

```swift
// swift-tools-version:5.9
import PackageDescription

let package = Package(
  name: "unbiased-ax",
  platforms: [.macOS(.v13)],
  products: [
    .executable(name: "unbiased-ax", targets: ["unbiased-ax"]),
    .library(name: "AXModel", targets: ["AXModel"]),
  ],
  targets: [
    // Pure. No AppKit, no ApplicationServices. Everything testable lives here.
    .target(name: "AXModel"),
    // The live adapter over AXUIElement / NSWorkspace.
    .target(
      name: "AXBridge",
      dependencies: ["AXModel"],
      linkerSettings: [.linkedFramework("ApplicationServices"), .linkedFramework("AppKit")]
    ),
    .executableTarget(name: "unbiased-ax", dependencies: ["AXModel", "AXBridge"]),
    // CommandLineTools ships neither XCTest nor Swift Testing, so tests are an
    // executable with its own 40-line harness. `swift run unbiased-ax-tests`.
    .executableTarget(name: "unbiased-ax-tests", dependencies: ["AXModel"]),
  ],
  swiftLanguageVersions: [.v5]
)
```

**Step 2: .gitignore**

```
.build/
dist/
*.xcodeproj
.DS_Store
```

**Step 3: README stub**

```markdown
# unbiased-ax

The accessibility bridge for unbiased-app's computer use: apps, windows, and
element trees as compact text with stable ids and diffs, plus actions on those
elements. One long-running process, newline-delimited JSON over stdio.

    swift build
    swift run unbiased-ax-tests     # the only test runner; exits non-zero on failure
    make bundle                     # dist/unbiased-ax + dist/manifest.json

Protocol: docs/PROTOCOL.md. Plan: docs/plans/.
```

**Step 4: Placeholder sources so the package builds**

`Sources/AXModel/AXModel.swift`:
```swift
/// Version of the wire protocol. Bump when a response shape changes.
public let protocolVersion = 1
```

`Sources/AXBridge/AXBridge.swift`:
```swift
import AXModel
```

`Sources/unbiased-ax/main.swift`:
```swift
import AXModel
print("unbiased-ax protocol \(protocolVersion)")
```

**Step 5: The harness**

`Sources/unbiased-ax-tests/Harness.swift`:
```swift
import Foundation

/// A test framework in 40 lines, because CommandLineTools has neither XCTest
/// nor Swift Testing. Each test file exposes `run<Name>Tests()`; main.swift
/// calls them in order and exits non-zero if anything failed.
struct Failure: Error, CustomStringConvertible { let description: String }

var passed = 0
var failed = 0

func test(_ name: String, _ body: () throws -> Void) {
  do {
    try body()
    passed += 1
    print("  ✔ \(name)")
  } catch {
    failed += 1
    print("  ✖ \(name)\n      \(error)")
  }
}

func expect(_ condition: Bool, _ message: @autoclosure () -> String = "expectation failed",
            file: String = #fileID, line: Int = #line) throws {
  if !condition { throw Failure(description: "\(message()) [\(file):\(line)]") }
}

func expectEqual<T: Equatable>(_ actual: T, _ expected: T,
                               file: String = #fileID, line: Int = #line) throws {
  try expect(actual == expected, "got \(String(reflecting: actual)), expected \(String(reflecting: expected))",
             file: file, line: line)
}

func finish() -> Never {
  print("\n\(passed) passed, \(failed) failed")
  exit(failed == 0 ? 0 : 1)
}
```

`Sources/unbiased-ax-tests/main.swift`:
```swift
import AXModel

print("AXModel")
test("protocol version is declared") { try expectEqual(protocolVersion, 1) }

finish()
```

**Step 6: Build and run the tests**

Run: `cd /Users/naveen/Projects/Work/unbiased-ax && swift build && swift run unbiased-ax-tests`
Expected: `Build complete!`, then `  ✔ protocol version is declared` and `1 passed, 0 failed`, exit 0.

**Step 7: Commit**

```bash
git add -A
printf 'chore: scaffold package, framework-free test harness\n\nCommandLineTools ships neither XCTest nor Swift Testing, so tests are a plain\nexecutable target with a 40-line harness. swift run unbiased-ax-tests is the\nonly test runner and exits non-zero on failure.\n' > /tmp/m.txt
git commit -F /tmp/m.txt
```

---

### Task 1: The element model and role normalization

**Files:**
- Create: `Sources/AXModel/Element.swift`
- Create: `Sources/unbiased-ax-tests/ElementTests.swift`
- Modify: `Sources/unbiased-ax-tests/main.swift`

**Step 1: Write the failing test**

`Sources/unbiased-ax-tests/ElementTests.swift`:
```swift
import AXModel

func runElementTests() {
  print("Element")
  test("AX role names are shortened to what a person would say") {
    try expectEqual(Role.normalize("AXButton"), "button")
    try expectEqual(Role.normalize("AXPopUpButton"), "pop up button")
    try expectEqual(Role.normalize("AXStaticText"), "text")
    try expectEqual(Role.normalize("AXTextField"), "text field")
    try expectEqual(Role.normalize("AXWebArea"), "web area")
    try expectEqual(Role.normalize("AXUnknown"), "unknown")
  }
  test("a role with a subrole shows the subrole when it is more specific") {
    try expectEqual(Role.normalize("AXWindow", subrole: "AXStandardWindow"), "standard window")
    try expectEqual(Role.normalize("AXButton", subrole: "AXCloseButton"), "close button")
    try expectEqual(Role.normalize("AXButton", subrole: nil), "button")
  }
  test("interactive roles are the ones a user can operate") {
    for r in ["button", "text field", "menu item", "link", "tab", "checkbox", "slider", "row", "cell"] {
      try expect(Role.isInteractive(r), "\(r) should be interactive")
    }
    for r in ["group", "text", "image", "unknown", "web area", "scroll area"] {
      try expect(!Role.isInteractive(r), "\(r) should be structural")
    }
  }
}
```

Add to `main.swift` before `finish()`: `runElementTests()`

**Step 2: Run test to verify it fails**

Run: `swift run unbiased-ax-tests`
Expected: compile error `cannot find 'Role' in scope`.

**Step 3: Write minimal implementation**

`Sources/AXModel/Element.swift`:
```swift
/// Element attributes, already read. Nothing here knows how they were read.
public struct Attributes: Equatable {
  public var role: String            // normalized: "button", "text field"
  public var title: String?
  public var value: String?
  public var x: Int, y: Int, width: Int, height: Int
  public var actions: [String]       // normalized: "press", "raise"
  public var enabled: Bool
  public var focused: Bool
  public var selected: Bool

  public init(role: String, title: String? = nil, value: String? = nil,
              x: Int = 0, y: Int = 0, width: Int = 0, height: Int = 0,
              actions: [String] = [], enabled: Bool = true, focused: Bool = false, selected: Bool = false) {
    self.role = role; self.title = title; self.value = value
    self.x = x; self.y = y; self.width = width; self.height = height
    self.actions = actions; self.enabled = enabled; self.focused = focused; self.selected = selected
  }
}

public enum Role {
  /// "AXPopUpButton" -> "pop up button". A subrole wins when it says more
  /// ("AXCloseButton" over "AXButton"); "AXStandardWindow" over "AXWindow".
  public static func normalize(_ role: String, subrole: String? = nil) -> String {
    if let sub = subrole, !sub.isEmpty, sub != "AXUnknown" { return words(sub) }
    return words(role)
  }

  private static func words(_ ax: String) -> String {
    var s = ax.hasPrefix("AX") ? String(ax.dropFirst(2)) : ax
    if s == "StaticText" { return "text" }
    // Split CamelCase into lowercase words: "PopUpButton" -> "pop up button".
    var out = ""
    for (i, ch) in s.enumerated() {
      if ch.isUppercase && i > 0 { out.append(" ") }
      out.append(ch.lowercased())
    }
    s = out
    return s
  }

  public static let interactive: Set<String> = [
    "button", "checkbox", "check box", "radio button", "pop up button", "menu button",
    "menu item", "menu bar item", "text field", "text area", "search field", "secure text field",
    "combo box", "slider", "link", "tab", "row", "cell", "disclosure triangle", "incrementor",
    "scroll bar", "toolbar", "window", "standard window", "dialog", "sheet", "close button",
    "minimize button", "zoom button", "full screen button",
  ]

  public static func isInteractive(_ role: String) -> Bool { interactive.contains(role) }
}
```

**Step 4: Run tests to verify they pass**

Run: `swift run unbiased-ax-tests`
Expected: all ✔, `4 passed, 0 failed`.

**Step 5: Commit**

```bash
git add -A
printf 'feat(model): element attributes and role normalization\n' > /tmp/m.txt && git commit -F /tmp/m.txt
```

---

### Task 2: Stable ids across snapshots

The whole point of ids is that the model can say `act 17` after reading a tree, and `17` still means the same button after the next snapshot. Ids are assigned per app, never reused within a session, and looked up by element *identity* — which, for the live adapter, is `CFEqual` on the `AXUIElement`. The model layer only sees an opaque `Hashable` identity.

**Files:**
- Create: `Sources/AXModel/IdRegistry.swift`
- Create: `Sources/unbiased-ax-tests/IdRegistryTests.swift`
- Modify: `Sources/unbiased-ax-tests/main.swift`

**Step 1: Write the failing test**

```swift
import AXModel

func runIdRegistryTests() {
  print("IdRegistry")
  test("the same identity keeps the same id across snapshots") {
    var reg = IdRegistry()
    let a = reg.id(for: "elem-a")
    let b = reg.id(for: "elem-b")
    try expect(a != b)
    try expectEqual(reg.id(for: "elem-a"), a)
    try expectEqual(reg.id(for: "elem-b"), b)
  }
  test("ids are never reused, even after an element disappears") {
    var reg = IdRegistry()
    let a = reg.id(for: "gone")
    reg.retain(only: [])           // a snapshot in which nothing survived
    let c = reg.id(for: "new")
    try expect(c != a, "a dead element's id must not be handed to a new one")
  }
  test("retain drops identities not seen, so memory does not grow forever") {
    var reg = IdRegistry()
    _ = reg.id(for: "x"); _ = reg.id(for: "y"); _ = reg.id(for: "z")
    reg.retain(only: ["y"])
    try expectEqual(reg.count, 1)
  }
  test("ids start at 1 and read like line numbers") {
    var reg = IdRegistry()
    try expectEqual(reg.id(for: "first"), 1)
    try expectEqual(reg.id(for: "second"), 2)
  }
}
```

Add `runIdRegistryTests()` to `main.swift`.

**Step 2: Run to verify failure** — `cannot find 'IdRegistry' in scope`.

**Step 3: Implementation**

`Sources/AXModel/IdRegistry.swift`:
```swift
/// Stable small integers for element identities. Never reuses an id: a model
/// that acts on `17` two turns later must either hit the same element or be
/// told it is gone, never silently hit a different one.
public struct IdRegistry {
  private var ids: [AnyHashable: Int] = [:]
  private var next = 1

  public init() {}

  public mutating func id(for identity: AnyHashable) -> Int {
    if let existing = ids[identity] { return existing }
    let id = next
    next += 1
    ids[identity] = id
    return id
  }

  public func identity(for id: Int) -> AnyHashable? {
    ids.first { $0.value == id }?.key
  }

  /// Forget everything not in `seen`. Called after each snapshot.
  public mutating func retain(only seen: Set<AnyHashable>) {
    ids = ids.filter { seen.contains($0.key) }
  }

  public var count: Int { ids.count }
}
```

**Step 4: Run** — `8 passed, 0 failed`.

**Step 5: Commit** — `feat(model): stable element ids that are never reused`

---

### Task 3: Snapshot builder with pruning and caps

This is where most of the token savings live. The builder walks an `ElementSource`, assigns ids, and drops what the model does not need: zero-size elements, and untitled structural containers (their children are hoisted up a level). It stops at a depth cap and an element cap and says so.

**Files:**
- Create: `Sources/AXModel/Snapshot.swift`
- Create: `Sources/unbiased-ax-tests/FakeSource.swift`
- Create: `Sources/unbiased-ax-tests/SnapshotTests.swift`
- Modify: `Sources/unbiased-ax-tests/main.swift`

**Step 1: The fake source (test-only)**

```swift
import AXModel

/// A tree described by hand. Identity is the node's path string, which is
/// what makes "the same button across two snapshots" expressible in a test.
final class FakeNode {
  let path: String
  var attrs: Attributes
  var children: [FakeNode]
  init(_ path: String, _ attrs: Attributes, _ children: [FakeNode] = []) {
    self.path = path; self.attrs = attrs; self.children = children
  }
}

struct FakeSource: ElementSource {
  typealias Node = FakeNode
  func identity(of node: FakeNode) -> AnyHashable { node.path }
  func attributes(of node: FakeNode) -> Attributes? { node.attrs }
  func children(of node: FakeNode) -> [FakeNode] { node.children }
}

func button(_ path: String, _ title: String, w: Int = 80, h: Int = 24) -> FakeNode {
  FakeNode(path, Attributes(role: "button", title: title, width: w, height: h, actions: ["press"]))
}
func group(_ path: String, _ children: [FakeNode], title: String? = nil) -> FakeNode {
  FakeNode(path, Attributes(role: "group", title: title, width: 500, height: 300), children)
}
```

**Step 2: Write the failing tests**

```swift
func runSnapshotTests() {
  print("Snapshot")
  let source = FakeSource()

  test("an untitled group is hoisted: its children take its place") {
    let root = group("w", [group("w/g", [button("w/g/ok", "OK"), button("w/g/cancel", "Cancel")])],
                     title: "Save")
    var reg = IdRegistry()
    let snap = Snapshot.build(root: root, source: source, registry: &reg, options: .init())
    try expectEqual(snap.nodes.map(\.attributes.title), ["Save", "OK", "Cancel"])
    try expectEqual(snap.nodes.map(\.depth), [0, 1, 1], "hoisted children sit at the group's depth")
  }
  test("a titled group is kept: the title is information") {
    let root = group("w", [group("w/g", [button("w/g/ok", "OK")], title: "Actions")], title: "Save")
    var reg = IdRegistry()
    let snap = Snapshot.build(root: root, source: source, registry: &reg, options: .init())
    try expectEqual(snap.nodes.map(\.attributes.title), ["Save", "Actions", "OK"])
  }
  test("zero-size elements are dropped along with their subtree") {
    let hidden = FakeNode("w/h", Attributes(role: "group", width: 0, height: 0), [button("w/h/x", "X")])
    let root = group("w", [hidden, button("w/ok", "OK")], title: "Save")
    var reg = IdRegistry()
    let snap = Snapshot.build(root: root, source: source, registry: &reg, options: .init())
    try expectEqual(snap.nodes.map(\.attributes.title), ["Save", "OK"])
  }
  test("depth is capped and the snapshot says so") {
    var deep = button("leaf", "Leaf")
    for i in (0..<20).reversed() { deep = group("g\(i)", [deep], title: "L\(i)") }
    var reg = IdRegistry()
    let snap = Snapshot.build(root: deep, source: source, registry: &reg, options: .init(maxDepth: 5))
    try expect(snap.nodes.count <= 6)
    try expect(snap.truncated, "must report truncation")
  }
  test("element count is capped and the snapshot says so") {
    let many = (0..<200).map { button("w/b\($0)", "B\($0)") }
    var reg = IdRegistry()
    let snap = Snapshot.build(root: group("w", many, title: "W"), source: source, registry: &reg,
                              options: .init(maxElements: 50))
    try expectEqual(snap.nodes.count, 50)
    try expect(snap.truncated)
  }
  test("the same element keeps its id across two snapshots") {
    let root = group("w", [button("w/ok", "OK"), button("w/cancel", "Cancel")], title: "Save")
    var reg = IdRegistry()
    let first = Snapshot.build(root: root, source: source, registry: &reg, options: .init())
    let okId = first.nodes.first { $0.attributes.title == "OK" }!.id
    root.children.insert(button("w/new", "New"), at: 0)      // something else appeared
    let second = Snapshot.build(root: root, source: source, registry: &reg, options: .init())
    try expectEqual(second.nodes.first { $0.attributes.title == "OK" }!.id, okId)
  }
  test("interactive-only mode keeps windows and controls, drops decoration") {
    let root = group("w", [FakeNode("w/t", Attributes(role: "text", title: "Hello", width: 50, height: 12)),
                           button("w/ok", "OK")], title: "Save")
    root.attrs.role = "standard window"
    var reg = IdRegistry()
    let snap = Snapshot.build(root: root, source: source, registry: &reg, options: .init(interactiveOnly: true))
    try expectEqual(snap.nodes.map(\.attributes.title), ["Save", "OK"])
  }
}
```

Add `runSnapshotTests()` to `main.swift`.

**Step 3: Run to verify failure** — `cannot find 'ElementSource'`.

**Step 4: Implementation**

`Sources/AXModel/Snapshot.swift`:
```swift
/// How a tree is read. The live adapter implements this over AXUIElement; the
/// tests implement it over a hand-built tree. Nothing else may read elements.
public protocol ElementSource {
  associatedtype Node
  func identity(of node: Node) -> AnyHashable
  /// nil means the element vanished between listing and reading; skip it.
  func attributes(of node: Node) -> Attributes?
  func children(of node: Node) -> [Node]
}

public struct SnapshotNode: Equatable {
  public var id: Int
  public var depth: Int
  public var attributes: Attributes
}

public struct SnapshotOptions {
  public var maxDepth: Int
  public var maxElements: Int
  public var interactiveOnly: Bool
  public init(maxDepth: Int = 14, maxElements: Int = 1500, interactiveOnly: Bool = false) {
    self.maxDepth = maxDepth; self.maxElements = maxElements; self.interactiveOnly = interactiveOnly
  }
}

public struct Snapshot: Equatable {
  public var nodes: [SnapshotNode]
  public var truncated: Bool

  /// Depth-first, in reading order. Pruning rules, each measured against real
  /// trees rather than guessed:
  ///  - zero-size elements and their subtrees are invisible: dropped.
  ///  - an untitled structural container carries no information: its children
  ///    are hoisted to its depth. Chromium nests a dozen of these per control.
  ///  - interactiveOnly additionally drops structural leaves (text, images).
  public static func build<S: ElementSource>(root: S.Node, source: S, registry: inout IdRegistry,
                                             options: SnapshotOptions) -> Snapshot {
    var nodes: [SnapshotNode] = []
    var seen = Set<AnyHashable>()
    var truncated = false

    func visit(_ node: S.Node, depth: Int) {
      if nodes.count >= options.maxElements { truncated = true; return }
      guard let attrs = source.attributes(of: node) else { return }
      if attrs.width == 0 || attrs.height == 0 { return }

      let structural = !Role.isInteractive(attrs.role)
      let untitled = (attrs.title ?? "").isEmpty && (attrs.value ?? "").isEmpty
      let kids = source.children(of: node)

      // Hoist: an untitled container with children says nothing itself.
      if structural && untitled && !kids.isEmpty && depth > 0 {
        for k in kids { visit(k, depth: depth) }
        return
      }
      if options.interactiveOnly && structural && kids.isEmpty && depth > 0 { return }

      let identity = source.identity(of: node)
      seen.insert(identity)
      nodes.append(SnapshotNode(id: registry.id(for: identity), depth: depth, attributes: attrs))

      if depth + 1 > options.maxDepth {
        if !kids.isEmpty { truncated = true }
        return
      }
      for k in kids { visit(k, depth: depth + 1) }
    }

    visit(root, depth: 0)
    registry.retain(only: seen)
    return Snapshot(nodes: nodes, truncated: truncated)
  }
}
```

**Step 5: Run** — all ✔.

**Step 6: Commit** — `feat(model): snapshot builder with hoisting, size pruning, depth and count caps`

---

### Task 4: The text format

One line per element, indented by depth. Compact but readable to a person, because the model reads it as a person would. Position and size are included only when the caller asks (`geometry: true`), because most turns are about *what* is there, not *where*.

Target format (geometry off):
```
1 standard window "Tame Impala - Loser - YouTube - Brave" {raise}
2   toolbar
3     text field "Address and search bar" = youtube.com/watch?v=… {press}
4     button "Reload" {press}
5   tab "Home / X" {press}
6   tab "Loser - YouTube" [selected] {press}
```
Geometry on appends `@x,y wxh`. Disabled appends `[disabled]`; focused appends `[focused]`.

**Files:**
- Create: `Sources/AXModel/Formatter.swift`
- Create: `Sources/unbiased-ax-tests/FormatterTests.swift`
- Modify: `main.swift`

**Step 1: Failing tests**

```swift
func runFormatterTests() {
  print("Formatter")
  func node(_ id: Int, _ depth: Int, _ a: Attributes) -> SnapshotNode { .init(id: id, depth: depth, attributes: a) }

  test("a line is id, role, quoted title, value, flags, actions") {
    let n = node(3, 2, Attributes(role: "text field", title: "Address and search bar",
                                  value: "youtube.com/", actions: ["press"], focused: true))
    try expectEqual(Formatter.line(n, geometry: false),
                    "3     text field \"Address and search bar\" = youtube.com/ [focused] {press}")
  }
  test("a bare structural element is just id and role") {
    try expectEqual(Formatter.line(node(2, 1, Attributes(role: "toolbar")), geometry: false), "2   toolbar")
  }
  test("geometry is appended only when asked") {
    let n = node(4, 1, Attributes(role: "button", title: "Reload", x: 10, y: 20, width: 30, height: 30, actions: ["press"]))
    try expectEqual(Formatter.line(n, geometry: true), "4   button \"Reload\" {press} @10,20 30x30")
    try expectEqual(Formatter.line(n, geometry: false), "4   button \"Reload\" {press}")
  }
  test("long values are clipped so one URL cannot flood the tree") {
    let long = String(repeating: "a", count: 500)
    let line = Formatter.line(node(1, 0, Attributes(role: "text field", value: long)), geometry: false)
    try expect(line.count < 200, "line was \(line.count) chars")
    try expect(line.contains("…"))
  }
  test("selected and disabled show as flags") {
    let n = node(6, 1, Attributes(role: "tab", title: "Loser", actions: ["press"], enabled: false, selected: true))
    try expectEqual(Formatter.line(n, geometry: false), "6   tab \"Loser\" [selected] [disabled] {press}")
  }
  test("a whole snapshot joins lines and reports truncation on its own line") {
    let snap = Snapshot(nodes: [node(1, 0, Attributes(role: "window", title: "W"))], truncated: true)
    try expectEqual(Formatter.render(snap, geometry: false),
                    "1 window \"W\"\n… truncated: raise depth or maxElements, or use find")
  }
}
```

**Step 2: Fails** — `cannot find 'Formatter'`.

**Step 3: Implementation**

`Sources/AXModel/Formatter.swift`:
```swift
public enum Formatter {
  public static let valueClip = 120

  public static func line(_ n: SnapshotNode, geometry: Bool) -> String {
    let a = n.attributes
    var parts: [String] = ["\(n.id)" + String(repeating: "  ", count: n.depth) + " " + a.role]
    // The id is not indented; the role is. Ids stay in a column a person can
    // scan, the indentation shows structure.
    parts = ["\(n.id) " + String(repeating: "  ", count: n.depth) + a.role]
    if let t = a.title, !t.isEmpty { parts.append("\"\(clip(t))\"") }
    if let v = a.value, !v.isEmpty { parts.append("= \(clip(v))") }
    if a.focused { parts.append("[focused]") }
    if a.selected { parts.append("[selected]") }
    if !a.enabled { parts.append("[disabled]") }
    if !a.actions.isEmpty { parts.append("{" + a.actions.joined(separator: ",") + "}") }
    if geometry { parts.append("@\(a.x),\(a.y) \(a.width)x\(a.height)") }
    return parts.joined(separator: " ")
  }

  public static func render(_ s: Snapshot, geometry: Bool) -> String {
    var lines = s.nodes.map { line($0, geometry: geometry) }
    if s.truncated { lines.append("… truncated: raise depth or maxElements, or use find") }
    return lines.joined(separator: "\n")
  }

  static func clip(_ s: String) -> String {
    let flat = s.replacingOccurrences(of: "\n", with: " ")
    return flat.count > valueClip ? String(flat.prefix(valueClip)) + "…" : flat
  }
}
```

Note the first `parts` assignment is dead and must be removed before commit — it is left in the plan so the executing engineer sees the reasoning about the id column, then deletes it. The final `line` begins with the second assignment.

**Step 4: Run** — all ✔. Check the exact spacing in the first test: id, one space, two spaces per depth, role.

**Step 5: Commit** — `feat(model): compact one-line-per-element text format`

---

### Task 5: Diffs between snapshots

After the first snapshot of an app, callers get only what changed. Same shape Codex uses: `~` changed, `+` added, removed summarized by id range. Matching is by stable id, which is why Task 2 mattered.

**Files:**
- Create: `Sources/AXModel/Differ.swift`
- Create: `Sources/unbiased-ax-tests/DifferTests.swift`
- Modify: `main.swift`

**Step 1: Failing tests**

```swift
func runDifferTests() {
  print("Differ")
  func node(_ id: Int, _ depth: Int, _ a: Attributes) -> SnapshotNode { .init(id: id, depth: depth, attributes: a) }
  let win = node(1, 0, Attributes(role: "window", title: "YouTube - Brave", actions: ["raise"]))

  test("nothing changed renders as exactly that") {
    let s = Snapshot(nodes: [win], truncated: false)
    try expectEqual(Differ.render(from: s, to: s, geometry: false), "(no changes)")
  }
  test("a changed attribute is a ~ line, unchanged elements are omitted") {
    let before = Snapshot(nodes: [win, node(2, 1, Attributes(role: "tab", title: "Home", actions: ["press"]))], truncated: false)
    let after  = Snapshot(nodes: [win, node(2, 1, Attributes(role: "tab", title: "Home", actions: ["press"], selected: true))], truncated: false)
    try expectEqual(Differ.render(from: before, to: after, geometry: false),
                    "~2   tab \"Home\" [selected] {press}")
  }
  test("a new element is a + line") {
    let before = Snapshot(nodes: [win], truncated: false)
    let after  = Snapshot(nodes: [win, node(3, 1, Attributes(role: "button", title: "Play", actions: ["press"]))], truncated: false)
    try expectEqual(Differ.render(from: before, to: after, geometry: false),
                    "+3   button \"Play\" {press}")
  }
  test("removed elements are summarized by id, not re-listed") {
    let before = Snapshot(nodes: [win, node(2, 1, Attributes(role: "tab", title: "A")),
                                  node(3, 1, Attributes(role: "tab", title: "B")),
                                  node(4, 1, Attributes(role: "tab", title: "C")),
                                  node(9, 1, Attributes(role: "tab", title: "D"))], truncated: false)
    let after  = Snapshot(nodes: [win], truncated: false)
    try expectEqual(Differ.render(from: before, to: after, geometry: false), "- removed: 2-4, 9")
  }
  test("a window title change is a ~ on the window") {
    let after = Snapshot(nodes: [node(1, 0, Attributes(role: "window", title: "Loser - Audio playing - Brave", actions: ["raise"]))], truncated: false)
    let out = Differ.render(from: Snapshot(nodes: [win], truncated: false), to: after, geometry: false)
    try expect(out.hasPrefix("~1 window \"Loser - Audio playing - Brave\""), out)
  }
}
```

**Step 2: Fails** — `cannot find 'Differ'`.

**Step 3: Implementation**

`Sources/AXModel/Differ.swift`:
```swift
public enum Differ {
  public static func render(from before: Snapshot, to after: Snapshot, geometry: Bool) -> String {
    let old = Dictionary(uniqueKeysWithValues: before.nodes.map { ($0.id, $0) })
    let new = Dictionary(uniqueKeysWithValues: after.nodes.map { ($0.id, $0) })
    var lines: [String] = []
    for n in after.nodes {
      if let o = old[n.id] {
        if o != n { lines.append("~" + Formatter.line(n, geometry: geometry)) }
      } else {
        lines.append("+" + Formatter.line(n, geometry: geometry))
      }
    }
    let removed = before.nodes.map(\.id).filter { new[$0] == nil }.sorted()
    if !removed.isEmpty { lines.append("- removed: " + ranges(removed)) }
    if after.truncated && !before.truncated { lines.append("… truncated") }
    return lines.isEmpty ? "(no changes)" : lines.joined(separator: "\n")
  }

  /// [2,3,4,9] -> "2-4, 9"
  static func ranges(_ ids: [Int]) -> String {
    var out: [String] = []
    var i = 0
    while i < ids.count {
      var j = i
      while j + 1 < ids.count && ids[j + 1] == ids[j] + 1 { j += 1 }
      out.append(i == j ? "\(ids[i])" : "\(ids[i])-\(ids[j])")
      i = j + 1
    }
    return out.joined(separator: ", ")
  }
}
```

**Step 4: Run** — all ✔.

**Step 5: Commit** — `feat(model): snapshot diffs — changed, added, removed by id range`

---

### Task 6: Wire protocol, codec, and dispatcher over a fake backend

The executable will be thin. All request handling lives in `Dispatcher`, which talks to a `Backend` protocol so the tests exercise every method and every error without touching AX.

**Files:**
- Create: `Sources/AXModel/Protocol.swift`
- Create: `Sources/AXModel/Dispatcher.swift`
- Create: `Sources/unbiased-ax-tests/DispatcherTests.swift`
- Create: `docs/PROTOCOL.md`
- Modify: `main.swift`

**Step 1: Failing tests**

```swift
import AXModel

/// A backend with two apps and a fixed tree, enough to drive every method.
final class FakeBackend: Backend {
  var trusted = true
  var acted: [(app: String, id: Int, action: String)] = []
  var setValues: [(app: String, id: Int, value: String)] = []
  var registries: [String: IdRegistry] = [:]
  let tree = group("w", [button("w/ok", "OK"), FakeNode("w/url", Attributes(role: "text field", title: "Address", value: "a.com", width: 300, height: 20))], title: "Win")

  func isTrusted() -> Bool { trusted }
  func apps() -> [AppInfo] { [AppInfo(pid: 10, name: "Brave Browser", bundleId: "com.brave.Browser", frontmost: true),
                              AppInfo(pid: 11, name: "Finder", bundleId: "com.apple.finder", frontmost: false)] }
  func windows(app: String) throws -> [WindowInfo] {
    guard app == "Brave Browser" else { throw BridgeError.noSuchApp(app) }
    return [WindowInfo(id: 1, title: "YouTube - Brave", x: 0, y: 0, width: 1200, height: 800, minimized: false, focused: true)]
  }
  func snapshot(app: String, options: SnapshotOptions) throws -> Snapshot {
    guard app == "Brave Browser" else { throw BridgeError.noSuchApp(app) }
    var reg = registries[app] ?? IdRegistry()
    defer { registries[app] = reg }
    return Snapshot.build(root: tree, source: FakeSource(), registry: &reg, options: options)
  }
  func perform(app: String, id: Int, action: String) throws { acted.append((app, id, action)) }
  func setValue(app: String, id: Int, value: String) throws { setValues.append((app, id, value)) }
  func raise(app: String, windowId: Int?) throws {}
}

func runDispatcherTests() {
  print("Dispatcher")
  func call(_ d: Dispatcher, _ json: String) -> String { d.handle(line: json) }

  test("hello reports the protocol version and trust state") {
    let d = Dispatcher(backend: FakeBackend())
    let out = call(d, #"{"id":1,"method":"hello"}"#)
    try expect(out.contains(#""protocolVersion":1"#), out)
    try expect(out.contains(#""trusted":true"#), out)
  }
  test("malformed JSON is an error response, never a crash, and keeps no id") {
    let out = call(Dispatcher(backend: FakeBackend()), "not json")
    try expect(out.contains(#""code":"bad_request""#), out)
  }
  test("an unknown method is reported by name") {
    let out = call(Dispatcher(backend: FakeBackend()), #"{"id":2,"method":"teleport"}"#)
    try expect(out.contains(#""code":"unknown_method""#), out)
  }
  test("every method except hello and apps refuses when not trusted, and says how to fix it") {
    let b = FakeBackend(); b.trusted = false
    let out = call(Dispatcher(backend: b), #"{"id":3,"method":"tree","params":{"app":"Brave Browser"}}"#)
    try expect(out.contains(#""code":"not_trusted""#), out)
    try expect(out.contains("Accessibility"), out)
  }
  test("tree returns rendered text, and the second call for the same app is a diff") {
    let d = Dispatcher(backend: FakeBackend())
    let first = call(d, #"{"id":4,"method":"tree","params":{"app":"Brave Browser"}}"#)
    try expect(first.contains("standard window") || first.contains("group"), first)
    try expect(first.contains(#""OK""#) || first.contains("OK"), first)
    let second = call(d, #"{"id":5,"method":"tree","params":{"app":"Brave Browser"}}"#)
    try expect(second.contains("(no changes)"), second)
  }
  test("full=true forces a complete tree even when a diff is available") {
    let d = Dispatcher(backend: FakeBackend())
    _ = call(d, #"{"id":6,"method":"tree","params":{"app":"Brave Browser"}}"#)
    let out = call(d, #"{"id":7,"method":"tree","params":{"app":"Brave Browser","full":true}}"#)
    try expect(!out.contains("(no changes)"), out)
  }
  test("an unknown app is a clear error") {
    let out = call(Dispatcher(backend: FakeBackend()), #"{"id":8,"method":"tree","params":{"app":"Nope"}}"#)
    try expect(out.contains(#""code":"no_such_app""#), out)
  }
  test("act performs the action and returns the diff that resulted") {
    let b = FakeBackend(); let d = Dispatcher(backend: b)
    _ = call(d, #"{"id":9,"method":"tree","params":{"app":"Brave Browser"}}"#)
    let out = call(d, #"{"id":10,"method":"act","params":{"app":"Brave Browser","id":2,"action":"press"}}"#)
    try expectEqual(b.acted.count, 1)
    try expectEqual(b.acted[0].action, "press")
    try expect(out.contains(#""diff""#), out)
  }
  test("act on an id the model never saw is refused, not guessed") {
    let d = Dispatcher(backend: FakeBackend())
    let out = call(d, #"{"id":11,"method":"act","params":{"app":"Brave Browser","id":999,"action":"press"}}"#)
    try expect(out.contains(#""code":"no_such_element""#), out)
  }
  test("setValue writes and returns the diff") {
    let b = FakeBackend(); let d = Dispatcher(backend: b)
    _ = call(d, #"{"id":12,"method":"tree","params":{"app":"Brave Browser"}}"#)
    _ = call(d, #"{"id":13,"method":"setValue","params":{"app":"Brave Browser","id":3,"value":"youtube.com"}}"#)
    try expectEqual(b.setValues.first?.value, "youtube.com")
  }
  test("find filters by role and title substring without a full dump") {
    let d = Dispatcher(backend: FakeBackend())
    let out = call(d, #"{"id":14,"method":"find","params":{"app":"Brave Browser","role":"button","title":"ok"}}"#)
    try expect(out.contains("OK"), out)
    try expect(!out.contains("Address"), out)
  }
  test("windows lists titles with geometry") {
    let out = call(Dispatcher(backend: FakeBackend()), #"{"id":15,"method":"windows","params":{"app":"Brave Browser"}}"#)
    try expect(out.contains("YouTube - Brave"), out)
    try expect(out.contains("1200x800"), out)
  }
  test("apps lists running apps with the frontmost marked") {
    let out = call(Dispatcher(backend: FakeBackend()), #"{"id":16,"method":"apps"}"#)
    try expect(out.contains("Brave Browser"), out)
    try expect(out.contains(#""frontmost":true"#), out)
  }
}
```

Add `runDispatcherTests()` to `main.swift`.

**Step 2: Fails** — `cannot find 'Backend'`.

**Step 3: Implementation**

`Sources/AXModel/Protocol.swift`:
```swift
import Foundation

public struct AppInfo: Codable, Equatable {
  public var pid: Int32, name: String, bundleId: String?, frontmost: Bool
  public init(pid: Int32, name: String, bundleId: String?, frontmost: Bool) {
    self.pid = pid; self.name = name; self.bundleId = bundleId; self.frontmost = frontmost
  }
}

public struct WindowInfo: Codable, Equatable {
  public var id: Int, title: String, x: Int, y: Int, width: Int, height: Int, minimized: Bool, focused: Bool
  public init(id: Int, title: String, x: Int, y: Int, width: Int, height: Int, minimized: Bool, focused: Bool) {
    self.id = id; self.title = title; self.x = x; self.y = y; self.width = width; self.height = height
    self.minimized = minimized; self.focused = focused
  }
}

public enum BridgeError: Error {
  case notTrusted
  case noSuchApp(String)
  case noSuchElement(Int)
  case noSuchWindow(Int)
  case actionFailed(String)
  case timeout(String)

  var code: String {
    switch self {
    case .notTrusted: return "not_trusted"
    case .noSuchApp: return "no_such_app"
    case .noSuchElement: return "no_such_element"
    case .noSuchWindow: return "no_such_window"
    case .actionFailed: return "action_failed"
    case .timeout: return "timeout"
    }
  }
  var message: String {
    switch self {
    case .notTrusted:
      return "This process has not been granted Accessibility access. System Settings > Privacy & Security > Accessibility, enable it, then restart."
    case .noSuchApp(let a): return "No running app matches \"\(a)\". Call apps to list them."
    case .noSuchElement(let id): return "No element \(id) in the last snapshot of this app. Call tree again."
    case .noSuchWindow(let id): return "No window \(id). Call windows."
    case .actionFailed(let m): return m
    case .timeout(let m): return "The app did not respond: \(m)"
    }
  }
}

/// What the live adapter provides. Everything the dispatcher needs, nothing more.
public protocol Backend: AnyObject {
  func isTrusted() -> Bool
  func apps() -> [AppInfo]
  func windows(app: String) throws -> [WindowInfo]
  func snapshot(app: String, options: SnapshotOptions) throws -> Snapshot
  func perform(app: String, id: Int, action: String) throws
  func setValue(app: String, id: Int, value: String) throws
  func raise(app: String, windowId: Int?) throws
}
```

`Sources/AXModel/Dispatcher.swift`:
```swift
import Foundation

/// One request line in, one response line out. Holds the last snapshot per
/// app so `tree` can answer with a diff and `act` can refuse unknown ids.
public final class Dispatcher {
  private let backend: Backend
  private var last: [String: Snapshot] = [:]

  public init(backend: Backend) { self.backend = backend }

  public func handle(line: String) -> String {
    guard let data = line.data(using: .utf8),
          let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let method = obj["method"] as? String else {
      return encode(["error": ["code": "bad_request", "message": "Each line must be a JSON object with a \"method\"."]])
    }
    let id = obj["id"]
    let params = obj["params"] as? [String: Any] ?? [:]
    do {
      let result = try dispatch(method, params)
      return encode(["id": id ?? NSNull(), "result": result])
    } catch let e as BridgeError {
      return encode(["id": id ?? NSNull(), "error": ["code": e.code, "message": e.message]])
    } catch {
      return encode(["id": id ?? NSNull(), "error": ["code": "internal", "message": "\(error)"]])
    }
  }

  private func dispatch(_ method: String, _ p: [String: Any]) throws -> Any {
    switch method {
    case "hello":
      return ["name": "unbiased-ax", "protocolVersion": protocolVersion, "trusted": backend.isTrusted()]
    case "apps":
      return ["apps": backend.apps().map(asDict)]
    default: break
    }
    guard backend.isTrusted() else { throw BridgeError.notTrusted }
    let app = try string(p, "app")
    switch method {
    case "windows":
      return ["windows": try backend.windows(app: app).map(asDict)]
    case "tree":
      let opts = options(p)
      let snap = try backend.snapshot(app: app, options: opts)
      let full = (p["full"] as? Bool) ?? false
      let geometry = (p["geometry"] as? Bool) ?? false
      defer { last[app] = snap }
      if let prev = last[app], !full {
        return ["diff": Differ.render(from: prev, to: snap, geometry: geometry), "count": snap.nodes.count, "truncated": snap.truncated]
      }
      return ["tree": Formatter.render(snap, geometry: geometry), "count": snap.nodes.count, "truncated": snap.truncated]
    case "find":
      let snap = try backend.snapshot(app: app, options: options(p))
      last[app] = snap
      let role = p["role"] as? String
      let title = (p["title"] as? String)?.lowercased()
      let hits = snap.nodes.filter { n in
        (role == nil || n.attributes.role == role!) &&
        (title == nil || (n.attributes.title ?? "").lowercased().contains(title!) || (n.attributes.value ?? "").lowercased().contains(title!))
      }
      return ["matches": hits.map { Formatter.line($0, geometry: (p["geometry"] as? Bool) ?? false) }, "count": hits.count]
    case "act":
      let id = try int(p, "id"); let action = try string(p, "action")
      try known(app, id)
      try backend.perform(app: app, id: id, action: action)
      return try afterAction(app, p)
    case "setValue":
      let id = try int(p, "id"); let value = try string(p, "value")
      try known(app, id)
      try backend.setValue(app: app, id: id, value: value)
      return try afterAction(app, p)
    case "raise":
      try backend.raise(app: app, windowId: p["window"] as? Int)
      return try afterAction(app, p)
    default:
      throw BridgeError.actionFailed("unknown method \(method)")  // replaced below
    }
  }

  /// Re-snapshot and return the diff: the model sees what its action did
  /// without a second round-trip.
  private func afterAction(_ app: String, _ p: [String: Any]) throws -> Any {
    let snap = try backend.snapshot(app: app, options: options(p))
    let diff = last[app].map { Differ.render(from: $0, to: snap, geometry: false) } ?? Formatter.render(snap, geometry: false)
    last[app] = snap
    return ["ok": true, "diff": diff]
  }

  private func known(_ app: String, _ id: Int) throws {
    guard let snap = last[app], snap.nodes.contains(where: { $0.id == id }) else { throw BridgeError.noSuchElement(id) }
  }

  private func options(_ p: [String: Any]) -> SnapshotOptions {
    var o = SnapshotOptions()
    if let d = p["depth"] as? Int { o.maxDepth = d }
    if let m = p["maxElements"] as? Int { o.maxElements = m }
    if let i = p["interactive"] as? Bool { o.interactiveOnly = i }
    return o
  }

  private func string(_ p: [String: Any], _ k: String) throws -> String {
    guard let v = p[k] as? String, !v.isEmpty else { throw BridgeError.actionFailed("missing \"\(k)\"") }
    return v
  }
  private func int(_ p: [String: Any], _ k: String) throws -> Int {
    guard let v = p[k] as? Int else { throw BridgeError.actionFailed("missing integer \"\(k)\"") }
    return v
  }
  private func asDict<T: Encodable>(_ v: T) -> Any {
    (try? JSONSerialization.jsonObject(with: JSONEncoder().encode(v))) ?? [:]
  }
  private func encode(_ obj: [String: Any]) -> String {
    guard let d = try? JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys]) else { return "{\"error\":{\"code\":\"internal\",\"message\":\"encode failed\"}}" }
    return String(decoding: d, as: UTF8.self)
  }
}
```

Then fix the `default:` branch: add `case unknownMethod(String)` to `BridgeError` with code `"unknown_method"` and message `"Unknown method \"\(m)\". Methods: hello, apps, windows, tree, find, act, setValue, raise."`, and throw it in both `default:` positions (the first switch needs no default — restructure so the `guard trusted` check is followed by one switch with a `default: throw BridgeError.unknownMethod(method)`). Note: for the unknown-method test to pass while untrusted checks come first, check the method name against the known set *before* the trust guard.

**Step 4: Run** — all ✔. The trickiest assertion is the diff-on-second-call; make sure `last[app]` is written after building the response (the `defer`).

**Step 5: docs/PROTOCOL.md** — write it from the tests: one section per method with request and response examples exactly as the tests send them, the error codes table, and the two rules the model must know: *ids are stable per app until the element disappears*, and *tree returns a diff after the first call unless `full` is true*.

**Step 6: Commit** — `feat(model): wire protocol and dispatcher, tested over a fake backend`

---

### Task 7: The stdio server

**Files:**
- Modify: `Sources/unbiased-ax/main.swift`
- Create: `Sources/unbiased-ax-tests/ServerTests.swift` (spawns the built binary)
- Modify: `main.swift` (tests), `Package.swift` (tests depend on nothing new; the server binary path is found relative to the test binary)

**Step 1: Failing test** — spawns `.build/debug/unbiased-ax`, writes two lines, reads two lines.

```swift
import Foundation
import AXModel

func runServerTests() {
  print("Server (spawns the built binary)")
  let bin = URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent().appendingPathComponent("unbiased-ax").path
  test("answers hello and survives a garbage line, one response per line") {
    let p = Process(); p.executableURL = URL(fileURLWithPath: bin)
    let inPipe = Pipe(), outPipe = Pipe()
    p.standardInput = inPipe; p.standardOutput = outPipe; p.standardError = FileHandle.nullDevice
    try p.run()
    inPipe.fileHandleForWriting.write("{\"id\":1,\"method\":\"hello\"}\nnot json\n{\"id\":2,\"method\":\"apps\"}\n".data(using: .utf8)!)
    inPipe.fileHandleForWriting.closeFile()
    p.waitUntilExit()
    let out = String(decoding: outPipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
    let lines = out.split(separator: "\n")
    try expectEqual(lines.count, 3)
    try expect(lines[0].contains("\"protocolVersion\":1"), String(lines[0]))
    try expect(lines[1].contains("bad_request"), String(lines[1]))
    try expect(lines[2].contains("\"apps\""), String(lines[2]))
    try expectEqual(p.terminationStatus, 0, "clean exit on EOF")
  }
}
```

**Step 2: Fails** — the binary prints a banner and exits, so 3 lines are not returned.

**Step 3: Implementation** — `Sources/unbiased-ax/main.swift`:
```swift
import Foundation
import AXModel
import AXBridge

// Newline-delimited JSON over stdio. One request per line, one response per
// line, in order. EOF on stdin is a clean shutdown. Nothing else is ever
// written to stdout; diagnostics go to stderr.
setvbuf(stdout, nil, _IOLBF, 0)
let dispatcher = Dispatcher(backend: LiveBackend())
while let line = readLine(strippingNewline: true) {
  if line.trimmingCharacters(in: .whitespaces).isEmpty { continue }
  print(dispatcher.handle(line: line))
}
```

`LiveBackend` does not exist yet: in this task create `Sources/AXBridge/LiveBackend.swift` as a stub that returns `isTrusted: AXIsProcessTrusted()`, real `apps()` via NSWorkspace, and throws `BridgeError.actionFailed("not implemented")` for the rest. Task 8 fills it in.

**Step 4: Run** — `swift build && swift run unbiased-ax-tests` — all ✔ (the test needs the server built first; `swift run` builds the whole package).

**Step 5: Commit** — `feat: stdio server — one JSON line in, one out, clean exit on EOF`

---

### Task 8: The live adapter — reading

This is the crux and it is not unit-testable without Accessibility permission, so the discipline is: keep it thin, keep every decision that *can* be pure in `AXModel`, and verify by hand against Finder with the documented commands. The `LiveBackend` must never hang and never crash on an app that vanishes mid-call.

**Files:**
- Create: `Sources/AXBridge/AXElement.swift`
- Create: `Sources/AXBridge/LiveSource.swift`
- Modify: `Sources/AXBridge/LiveBackend.swift`

**Step 1: `AXElement` — a Hashable wrapper so the registry can key on identity**

```swift
import ApplicationServices

/// AXUIElementRef with value semantics for hashing: two refs to the same
/// on-screen element are CFEqual, which is what "the same button as last
/// snapshot" means.
struct AXElement: Hashable {
  let ref: AXUIElement
  static func == (a: AXElement, b: AXElement) -> Bool { CFEqual(a.ref, b.ref) }
  func hash(into h: inout Hasher) { h.combine(CFHash(ref)) }
}
```

**Step 2: `LiveSource` — one IPC per element**

```swift
import ApplicationServices
import AXModel

/// Reads elements over the Accessibility API. All attributes of an element
/// come back in ONE call (AXUIElementCopyMultipleAttributeValues); the naive
/// one-call-per-attribute approach is 8x the IPC on a Chromium tree.
struct LiveSource: ElementSource {
  typealias Node = AXElement

  static let wanted: [String] = [
    kAXRoleAttribute, kAXSubroleAttribute, kAXTitleAttribute, kAXValueAttribute, kAXDescriptionAttribute,
    kAXPositionAttribute, kAXSizeAttribute, kAXEnabledAttribute, kAXFocusedAttribute, kAXSelectedAttribute,
  ]

  func identity(of node: AXElement) -> AnyHashable { node }

  func attributes(of node: AXElement) -> Attributes? {
    var values: CFArray?
    let err = AXUIElementCopyMultipleAttributeValues(node.ref, Self.wanted as CFArray, AXCopyMultipleAttributeOptions(), &values)
    guard err == .success, let arr = values as? [AnyObject], arr.count == Self.wanted.count else { return nil }

    func str(_ i: Int) -> String? {
      let v = arr[i]
      if CFGetTypeID(v) == AXValueGetTypeID() { return nil }          // an error placeholder
      if let s = v as? String { return s }
      if let n = v as? NSNumber { return n.stringValue }
      if let u = v as? URL { return u.absoluteString }
      return nil
    }
    func bool(_ i: Int) -> Bool { (arr[i] as? Bool) ?? false }
    func point(_ i: Int) -> CGPoint { var p = CGPoint.zero; if CFGetTypeID(arr[i]) == AXValueGetTypeID() { AXValueGetValue(arr[i] as! AXValue, .cgPoint, &p) }; return p }
    func size(_ i: Int) -> CGSize { var s = CGSize.zero; if CFGetTypeID(arr[i]) == AXValueGetTypeID() { AXValueGetValue(arr[i] as! AXValue, .cgSize, &s) }; return s }

    let role = Role.normalize(str(0) ?? "AXUnknown", subrole: str(1))
    // Title, else description: many controls only have the latter.
    let title = str(2).flatMap { $0.isEmpty ? nil : $0 } ?? str(4)
    let p = point(5), s = size(6)

    var names: CFArray?
    var actions: [String] = []
    if AXUIElementCopyActionNames(node.ref, &names) == .success, let a = names as? [String] {
      actions = a.map { Role.normalizeAction($0) }
    }
    return Attributes(role: role, title: title, value: str(3),
                      x: Int(p.x), y: Int(p.y), width: Int(s.width), height: Int(s.height),
                      actions: actions, enabled: bool(7), focused: bool(8), selected: bool(9))
  }

  func children(of node: AXElement) -> [AXElement] {
    var v: CFTypeRef?
    guard AXUIElementCopyAttributeValue(node.ref, kAXChildrenAttribute as CFString, &v) == .success,
          let arr = v as? [AXUIElement] else { return [] }
    return arr.map(AXElement.init)
  }
}
```

Add to `Role` in AXModel: `public static func normalizeAction(_ ax: String) -> String` — `"AXPress" -> "press"`, `"AXRaise" -> "raise"`, `"AXShowMenu" -> "show menu"`, otherwise `words(ax)`. Add a test for it in `ElementTests`.

**Step 3: `LiveBackend` — apps, windows, snapshot**

```swift
import AppKit
import ApplicationServices
import AXModel

public final class LiveBackend: Backend {
  private var registries: [pid_t: IdRegistry] = [:]
  private var elements: [pid_t: [Int: AXElement]] = [:]   // id -> element, from the last snapshot

  public init() {}

  public func isTrusted() -> Bool { AXIsProcessTrusted() }

  public func apps() -> [AppInfo] {
    NSWorkspace.shared.runningApplications
      .filter { $0.activationPolicy == .regular }
      .map { AppInfo(pid: $0.processIdentifier, name: $0.localizedName ?? "?", bundleId: $0.bundleIdentifier, frontmost: $0.isActive) }
  }

  /// Name, bundle id, or pid — case-insensitive, prefix-tolerant ("Brave" finds "Brave Browser").
  func resolve(_ app: String) throws -> NSRunningApplication {
    let apps = NSWorkspace.shared.runningApplications.filter { $0.activationPolicy == .regular }
    if let pid = Int32(app), let a = apps.first(where: { $0.processIdentifier == pid }) { return a }
    let q = app.lowercased()
    if let a = apps.first(where: { $0.bundleIdentifier?.lowercased() == q || $0.localizedName?.lowercased() == q }) { return a }
    if let a = apps.first(where: { ($0.localizedName ?? "").lowercased().hasPrefix(q) }) { return a }
    throw BridgeError.noSuchApp(app)
  }

  private func appElement(_ a: NSRunningApplication) -> AXElement {
    let e = AXUIElementCreateApplication(a.processIdentifier)
    // Never let one unresponsive app hang the whole bridge.
    AXUIElementSetMessagingTimeout(e, 1.0)
    return AXElement(ref: e)
  }

  public func windows(app: String) throws -> [WindowInfo] {
    let a = try resolve(app)
    let root = appElement(a)
    var v: CFTypeRef?
    guard AXUIElementCopyAttributeValue(root.ref, kAXWindowsAttribute as CFString, &v) == .success,
          let wins = v as? [AXUIElement] else { return [] }
    let src = LiveSource()
    var reg = registries[a.processIdentifier] ?? IdRegistry()
    var out: [WindowInfo] = []
    for w in wins {
      let el = AXElement(ref: w)
      guard let at = src.attributes(of: el) else { continue }
      var minimized: CFTypeRef?
      AXUIElementCopyAttributeValue(w, kAXMinimizedAttribute as CFString, &minimized)
      let id = reg.id(for: el)
      elements[a.processIdentifier, default: [:]][id] = el
      out.append(WindowInfo(id: id, title: at.title ?? "", x: at.x, y: at.y, width: at.width, height: at.height,
                            minimized: (minimized as? Bool) ?? false, focused: at.focused))
    }
    registries[a.processIdentifier] = reg
    return out
  }

  public func snapshot(app: String, options: SnapshotOptions) throws -> Snapshot {
    let a = try resolve(app)
    let root = appElement(a)
    var reg = registries[a.processIdentifier] ?? IdRegistry()
    let snap = Snapshot.build(root: root, source: LiveSource(), registry: &reg, options: options)
    registries[a.processIdentifier] = reg
    // Keep the element behind each id so act/setValue can find it.
    var map: [Int: AXElement] = [:]
    for n in snap.nodes { if let ident = reg.identity(for: n.id)?.base as? AXElement { map[n.id] = ident } }
    elements[a.processIdentifier] = map
    return snap
  }

  public func perform(app: String, id: Int, action: String) throws { throw BridgeError.actionFailed("Task 9") }
  public func setValue(app: String, id: Int, value: String) throws { throw BridgeError.actionFailed("Task 9") }
  public func raise(app: String, windowId: Int?) throws { throw BridgeError.actionFailed("Task 9") }
}
```

`IdRegistry.identity(for:)` is O(n); add a reverse map inside the registry (`byId: [Int: AnyHashable]`) so it is O(1), and add a test that `identity(for:)` returns what `id(for:)` was given.

**Step 4: Build** — `swift build` clean, tests still all ✔ (nothing here is unit-tested; that is deliberate and stated).

**Step 5: Manual verification against Finder** (this is the test for this task; record the output in the commit message):

```bash
swift build
# Grant Accessibility to the *terminal* running this, or the calls return not_trusted.
printf '{"id":1,"method":"hello"}\n{"id":2,"method":"windows","params":{"app":"Finder"}}\n{"id":3,"method":"tree","params":{"app":"Finder","interactive":true,"depth":8}}\n' | .build/debug/unbiased-ax
```
Expected: `hello` with `"trusted":true`; a windows list with real Finder window titles; a tree whose first line is a `standard window` and which contains toolbar buttons with `{press}`. If `trusted` is false, the terminal app needs the grant — that is the environment, not the code.

Measure: `time` the tree call on Brave with a dozen tabs. Target under 400ms. If it is over a second, the likely culprit is `AXUIElementCopyActionNames` being called on every node; move it behind `interactiveOnly`-relevant roles only.

**Step 6: Commit** — `feat(bridge): live adapter over AXUIElement — apps, windows, snapshot`

---

### Task 9: The live adapter — acting

**Files:**
- Modify: `Sources/AXBridge/LiveBackend.swift`

**Step 1: Implementation**

```swift
  private func element(_ app: String, _ id: Int) throws -> (NSRunningApplication, AXElement) {
    let a = try resolve(app)
    guard let el = elements[a.processIdentifier]?[id] else { throw BridgeError.noSuchElement(id) }
    return (a, el)
  }

  public func perform(app: String, id: Int, action: String) throws {
    let (_, el) = try element(app, id)
    let ax: String
    switch action {
    case "press": ax = kAXPressAction
    case "raise": ax = kAXRaiseAction
    case "show menu": ax = kAXShowMenuAction
    case "focus":
      let err = AXUIElementSetAttributeValue(el.ref, kAXFocusedAttribute as CFString, kCFBooleanTrue)
      guard err == .success else { throw BridgeError.actionFailed("focus failed: \(err.rawValue)") }
      return
    default: ax = "AX" + action.split(separator: " ").map { $0.capitalized }.joined()
    }
    let err = AXUIElementPerformAction(el.ref, ax as CFString)
    switch err {
    case .success: return
    case .cannotComplete: throw BridgeError.timeout("action \(action) on element \(id)")
    default: throw BridgeError.actionFailed("\(action) failed (AXError \(err.rawValue)). Actions this element supports are listed in braces in the tree.")
    }
  }

  public func setValue(app: String, id: Int, value: String) throws {
    let (_, el) = try element(app, id)
    // Focusing first matters for text fields in Chromium: the value is
    // accepted but not committed to the omnibox without focus.
    AXUIElementSetAttributeValue(el.ref, kAXFocusedAttribute as CFString, kCFBooleanTrue)
    let err = AXUIElementSetAttributeValue(el.ref, kAXValueAttribute as CFString, value as CFTypeRef)
    guard err == .success else { throw BridgeError.actionFailed("setValue failed (AXError \(err.rawValue)); the element may be read-only") }
  }

  public func raise(app: String, windowId: Int?) throws {
    let a = try resolve(app)
    // Bring the app forward first: AXRaise on a window of a background app is
    // honoured only once the app is active. This works across Spaces, which is
    // the whole reason the screenshot approach lost Brave.
    a.activate(options: [])
    if let id = windowId {
      guard let w = elements[a.processIdentifier]?[id] else { throw BridgeError.noSuchWindow(id) }
      let err = AXUIElementPerformAction(w.ref, kAXRaiseAction as CFString)
      guard err == .success else { throw BridgeError.actionFailed("raise failed (AXError \(err.rawValue))") }
    }
  }
```

**Step 2: Manual verification** — the task the whole thing exists for, end to end by hand:

```bash
printf '{"id":1,"method":"raise","params":{"app":"Brave"}}\n{"id":2,"method":"find","params":{"app":"Brave","role":"text field","title":"address"}}\n' | .build/debug/unbiased-ax
# take the id of the address field from the find output, then:
printf '{"id":3,"method":"tree","params":{"app":"Brave","interactive":true}}\n{"id":4,"method":"setValue","params":{"app":"Brave","id":<ID>,"value":"https://www.youtube.com/watch?v=dQw4w9WgXcQ"}}\n{"id":5,"method":"act","params":{"app":"Brave","id":<ID>,"action":"press"}}\n' | .build/debug/unbiased-ax
```
Expected: Brave comes to the front (from whatever Space it was on), the omnibox takes the URL, the returned diff shows the window title changing. Record what actually happened in the commit message, including anything that did not work.

**Step 3: Commit** — `feat(bridge): act, setValue, raise — with the diff of what they did`

---

### Task 10: Chromium web content, opt-in

Chromium builds its web-content accessibility tree only when something asks for it. Setting `AXEnhancedUserInterface` on the app element is how VoiceOver asks. It is opt-in per request (`web: true`) because it makes Chromium do measurable extra work for every page.

**Files:**
- Modify: `Sources/AXModel/Snapshot.swift` (`SnapshotOptions.webContent: Bool`)
- Modify: `Sources/AXModel/Dispatcher.swift` (`options()` reads `p["web"]`)
- Modify: `Sources/AXBridge/LiveBackend.swift`
- Modify: `Sources/unbiased-ax-tests/DispatcherTests.swift` (one test that `web` reaches the backend options)

**Step 1: Failing test** — FakeBackend records the options it received; assert `webContent == true` for `{"web":true}`.

**Step 2: Implementation** — in `snapshot(app:options:)`, before building:
```swift
    if options.webContent {
      AXUIElementSetAttributeValue(root.ref, "AXEnhancedUserInterface" as CFString, kCFBooleanTrue)
    }
```

**Step 3: Manual check** — `tree` on Brave with `"web":true` on a YouTube page should now include `web area` and, under it, `button "Play"` / `link` elements. Note the tree is large: use `"interactive":true` and `find` rather than the full dump. Record the element count and timing with and without `web` in the commit message; that number decides the default.

**Step 4: Commit** — `feat(bridge): opt-in Chromium web content via AXEnhancedUserInterface`

---

### Task 11: Bundle, sign, manifest

unbiased-app locates its sidecars through a manifest next to the binary. Mirror that shape exactly so the app-side integration is a few lines.

**Files:**
- Create: `Makefile`
- Create: `scripts/bundle.sh`

**Step 1: Makefile**

```makefile
.PHONY: build test bundle clean
build:
	swift build -c release
test:
	swift run unbiased-ax-tests
bundle: build
	scripts/bundle.sh
clean:
	rm -rf .build dist
```

**Step 2: scripts/bundle.sh**

```bash
#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
mkdir -p dist
cp .build/release/unbiased-ax dist/unbiased-ax
# Ad-hoc, with a STABLE identifier and a designated requirement on that
# identifier: the Accessibility grant is keyed to the signature, and this is
# what lets a rebuilt binary keep the grant instead of asking again.
codesign --force --sign - --identifier ai.unbiased.ax \
  --requirements '=designated => identifier "ai.unbiased.ax"' --timestamp=none dist/unbiased-ax
version=$(git describe --tags --always 2>/dev/null || echo 0.1.0)
cat > dist/manifest.json <<EOF
{
  "name": "unbiased-ax",
  "version": "$version",
  "protocolVersion": 1,
  "runtime": "native",
  "entry": "unbiased-ax",
  "args": [],
  "builtAt": "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
}
EOF
echo "dist/unbiased-ax ($(du -h dist/unbiased-ax | cut -f1)), dist/manifest.json"
```

`chmod +x scripts/bundle.sh`.

**Step 3: Run** — `make bundle`; then `printf '{"id":1,"method":"hello"}\n' | dist/unbiased-ax` answers; `codesign --verify --strict dist/unbiased-ax` is silent (valid).

**Step 4: Commit** — `build: release bundle with stable ad-hoc identity and manifest`

---

### Task 12: README and the integration handoff

**Files:**
- Modify: `README.md`
- Create: `docs/INTEGRATION.md`

`README.md`: what it is, the three commands, a five-line example session (hello → apps → tree → act → the diff that came back), the performance choices as a short list with the measured numbers from Tasks 8 and 10, and the permission requirement.

`docs/INTEGRATION.md`: how unbiased-app consumes this, as a follow-up plan for *that* repo, not this one:
1. `resolveSidecarDir`-style discovery, accepting `runtime: "native"` in `readSidecarManifest`.
2. Spawn once at startup after the engine connects; the Accessibility grant belongs to whatever bundle spawns it — inside `Unbiased.app` via `extraResources`, so the existing grant covers it.
3. Two dynamic tools first: `computer_app_state(app, interactive?, web?, full?)` → tree or diff, and `computer_act(app, id, action | value)` → the diff. Add `computer_raise(app)`. Approval stays per action for now.
4. Then code mode: register the bridge as an MCP server with `tool_mode = "code_mode_only"` and enable `features.code_mode` in the engine config, once `codex-code-mode-host` provenance is confirmed in the open-source codex repo.
5. Screenshots remain the fallback for content the tree does not expose.

**Commit** — `docs: README and the unbiased-app integration handoff`

---

## Done when

- `swift run unbiased-ax-tests` prints `N passed, 0 failed` with N ≥ 40.
- `make bundle` produces a signed `dist/unbiased-ax` that answers `hello`.
- By hand, against real Brave: `raise` brings it to the front from another Space, `find` locates the address field, `setValue` + `press` navigates, and the returned diff shows the title change — the sequence that took 27 tool calls on 2026-09-03, in 4.
