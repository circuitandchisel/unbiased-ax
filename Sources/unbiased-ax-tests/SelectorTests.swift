import AXModel

private func node(_ id: Int, _ depth: Int, _ role: String, _ title: String? = nil,
                  value: String? = nil, actions: [String] = [], enabled: Bool = true,
                  selected: Bool = false) -> SnapshotNode {
  SnapshotNode(id: id, depth: depth,
               attributes: Attributes(role: role, title: title, value: value,
                                      actions: actions, enabled: enabled, selected: selected))
}

/// Two panels that both contain a "Billing" tab, which is the situation a
/// selector has to survive: the label alone is not unique anywhere real.
private let tree: [SnapshotNode] = [
  node(1, 0, "window", "Settings"),
  node(2, 1, "group", "Workspace settings"),
  node(3, 2, "tab button", "Overview", value: "1", actions: ["press"], selected: true),
  node(4, 2, "tab button", "Billing", value: "0", actions: ["press"]),
  node(5, 2, "text", "Billing"),
  node(6, 1, "group", "Personal settings"),
  node(7, 2, "tab button", "Billing", value: "0", actions: ["press"]),
  node(8, 2, "button", "Save", actions: ["press"], enabled: false),
]

func runSelectorTests() {
  print("Selectors")

  test("a description that fits exactly one element resolves") {
    guard case .one(let n) = SelectorEngine.resolve(tree, Selector(role: "button", label: "Save")) else {
      try expect(false, "expected one"); return
    }
    try expectEqual(n.id, 8)
  }

  test("a label that fits several refuses, and hands back all of them") {
    guard case .many(let hits) = SelectorEngine.resolve(tree, Selector(label: "Billing")) else {
      try expect(false, "expected many"); return
    }
    // Three: two tab buttons and the static text that happens to say the same.
    try expectEqual(hits.count, 3)
  }

  test("a role narrows it, and an ancestor finishes the job") {
    // Role alone still leaves two tabs, one per panel.
    guard case .many = SelectorEngine.resolve(tree, Selector(role: "tab button", label: "Billing")) else {
      try expect(false, "role alone should still be ambiguous here"); return
    }
    // Scoped to one panel it is unique — which is what `within` is for.
    guard case .one(let n) = SelectorEngine.resolve(tree, Selector(role: "tab button", label: "Billing", within: 2)) else {
      try expect(false, "within should have resolved it"); return
    }
    try expectEqual(n.id, 4)
  }

  test("an ancestor scope stops at its own subtree") {
    let scoped = SelectorEngine.scope(tree, within: 6)
    try expectEqual(scoped.map(\.id), [7, 8])
  }

  test("nothing matching comes back with what almost did") {
    guard case .none(let near) = SelectorEngine.resolve(tree, Selector(role: "tab button", label: "Access")) else {
      try expect(false, "expected none"); return
    }
    // Same role, different label: the caller probably wants one of these.
    try expect(near.allSatisfy { $0.attributes.role == "tab button" }, "near misses: \(near.map(\.id))")
    try expect(!near.isEmpty, "a near miss is what makes not_found actionable")
  }

  test("matching is exact unless asked otherwise") {
    // "Save" must not match "Save as…" — this is how the wrong button is pressed.
    let partial = Selector(label: "Sav")
    guard case .none = SelectorEngine.resolve(tree, partial) else {
      try expect(false, "a prefix must not match by default"); return
    }
    guard case .one(let n) = SelectorEngine.resolve(tree, Selector(role: "button", label: "Sav", contains: true)) else {
      try expect(false, "contains was asked for and should match"); return
    }
    try expectEqual(n.id, 8)
  }

  test("case is respected unless asked otherwise") {
    guard case .none = SelectorEngine.resolve(tree, Selector(role: "button", label: "save")) else {
      try expect(false, "case must matter by default"); return
    }
    guard case .one = SelectorEngine.resolve(tree, Selector(role: "button", label: "save", caseInsensitive: true)) else {
      try expect(false, "caseInsensitive was asked for"); return
    }
  }

  test("state narrows: an action separates a control from the text that labels it") {
    guard case .one(let n) = SelectorEngine.resolve(tree, Selector(label: "Billing", action: "press", within: 2)) else {
      try expect(false, "expected the pressable one"); return
    }
    try expectEqual(n.id, 4)
  }

  test("enabled and selected are matchable, and false is not the same as unset") {
    guard case .one(let off) = SelectorEngine.resolve(tree, Selector(role: "button", enabled: false)) else {
      try expect(false, "expected the disabled button"); return
    }
    try expectEqual(off.id, 8)
    guard case .one(let on) = SelectorEngine.resolve(tree, Selector(role: "tab button", selected: true)) else {
      try expect(false, "expected the selected tab"); return
    }
    try expectEqual(on.id, 3)
  }

  test("an empty selector is not a match-everything") {
    // Guarded at the dispatcher, but the engine must not pretend either.
    try expect(Selector().isEmpty)
    try expect(!Selector(role: "button").isEmpty)
  }
}
