# Figma-run follow-ups: fewer compactions, no read-after-write, a checkpoint that survives compaction

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task. TDD on every task: write the test, watch it fail, make it pass, commit.

**Goal:** Cut the four measured wastes in the 2026-09-08 Figma logo run (32m34s vs Codex 5m38s): 20 forced full trees that drove two compactions, 54 read-only turns spent re-checking fields the batch had just written, reproachful tool text that started re-plan turns, and the loss of working state at each compaction.

**Architecture:** Two repos move together, as with cross-Space. Bridge (Part A, Swift, `unbiased-ax`): diff baselines become per-(app, filter) so a filter flip yields a diff instead of a full tree; a `values` verb reads back a set of ids cheaply; `key escape` no longer pays the shrink deadline. App (Part B, TypeScript, `unbiased-app`): stop forcing `full` on filter switch; after every batch read back every field it touched and print them; rewrite the two scolding sentences as facts; a `checkpoint_save` tool plus a threshold gate that fires before the engine compacts, an app-recorded ledger of measured facts, and an automatic re-send of the checkpoint on the first tool result after a compaction.

**Tech Stack:** Swift 5.9 package (`make test` = `swift build && swift run unbiased-ax-tests`, executable harness, no XCTest); Electron main process in TypeScript (`npm test` = `node --import tsx --test src/main/*.test.ts`, `npm run typecheck`).

**Trees:**
- Bridge: `/Users/naveen/Projects/Work/unbiased-ax/.claude/worktrees/folder-comprehension-subagents-4e96f9` on `naveen/folder-comprehension-subagents-4e96f9` (= `main` @ `96fa7b3`).
- App: `/Users/naveen/Projects/Work/unbiased-app/.claude/worktrees/figma-followups-4e96f9` on `naveen/figma-followups-4e96f9` (= `main` @ `5585020`).
- Do NOT touch `.claude/worktrees/agitated-wilbur-0ab621` (app) or `.claude/worktrees/repo-comprehension-579cb2` (bridge): another session works there.

**Measured facts this plan rests on** (diag log 15:26–15:58 UTC, rollout `01a081a0-…`): 171 tool calls, 87 model turns, 117s in tools (6%), median model gap 8.9s; compactions at 15:40:34 and 15:49:30 with a 124,518-token window; 54 `computer_app_state` calls of which 32 were `query`, 14 asked `full:true`, 28 flipped `web`/`interactive` between consecutive reads; 20 full trees ≈ 185KB; the four-step stepper recipe (`pointer`,`⌘a`,`type`,`return`) bypasses `verifyValue`, so the model re-read after every batch; 14 turns opened "You're right/Good call" with no human in the loop, three of them reacting to `ACTION_NO_CHANGE_SENTENCE` or the batch caveat; `escape` after Figma's colour picker hit the 3.5s shrink deadline 8 times.

**Explicitly out of scope:** code mode (INTEGRATION.md stage 4; engine-gated), Figma-specific guidance in the skill, CHANGELOG entries (release-time), pushing/merging to `main` (the user's call).

---

## Part A — bridge

### Task A1: Diff baselines are per (app, filter)

A filter flip (`interactive`, `web`, `depth`, `maxElements`) today forces the app to ask `full:true`, because the bridge holds ONE baseline per app and a diff across filters is a lie (everything the old filter hid shows as added). Hold one baseline per filter instead: a flip diffs against that filter's own last read, and only a filter never read before gets a full tree. Ids stay valid across filters — they come from the per-app registry, so an id seen under any filter is actable.

**Files:**
- Modify: `Sources/AXModel/Dispatcher.swift` (`private var last`, `tree`, `find`, `launch`, `afterAction`, `resolveId`, `offers`)
- Create: `Sources/unbiased-ax-tests/BaselineTests.swift`
- Modify: `Sources/unbiased-ax-tests/main.swift` (register `runBaselineTests()`)
- Modify: `docs/PROTOCOL.md` line ~30 ("find, launch and every action reset the baseline")

**Step 1: Write the failing tests**

`Sources/unbiased-ax-tests/BaselineTests.swift`:

```swift
import AXModel

func runBaselineTests() {
  print("Baselines (one per filter)")
  func call(_ d: Dispatcher, _ json: String) -> String { d.handle(line: json) }

  // Measured 2026-09-08: 28 filter flips in one Figma run, each forced a full
  // tree (~9KB), and the two compactions that followed cost nine minutes. A
  // flip is not a reason to resend everything: diff against that filter's own
  // last read.
  test("a read under a new filter is a full tree; a read under a seen filter is a diff") {
    let d = Dispatcher(backend: FakeBackend())
    let a1 = call(d, #"{"id":1,"method":"tree","params":{"app":"Brave Browser"}}"#)
    try expect(a1.contains(#""tree":"#), a1)
    let b1 = call(d, #"{"id":2,"method":"tree","params":{"app":"Brave Browser","interactive":true}}"#)
    try expect(b1.contains(#""tree":"#), "first read under interactive:true has no baseline of its own: \(b1)")
    let a2 = call(d, #"{"id":3,"method":"tree","params":{"app":"Brave Browser"}}"#)
    try expect(a2.contains(#""diff":"(no changes)""#), "the default filter's baseline must survive a read under another filter: \(a2)")
    let b2 = call(d, #"{"id":4,"method":"tree","params":{"app":"Brave Browser","interactive":true}}"#)
    try expect(b2.contains(#""diff":"(no changes)""#), b2)
  }

  test("a change is reported once per filter, against that filter's own last read") {
    let b = FakeBackend()
    let d = Dispatcher(backend: b)
    _ = call(d, #"{"id":1,"method":"tree","params":{"app":"Brave Browser"}}"#)
    _ = call(d, #"{"id":2,"method":"tree","params":{"app":"Brave Browser","interactive":true}}"#)
    b.snapshotsUntilChange = b.snapshotCount // every snapshot from here on carries the late "Result" button
    let a = call(d, #"{"id":3,"method":"tree","params":{"app":"Brave Browser"}}"#)
    try expect(a.contains("Result"), "the default filter sees the new node: \(a)")
    let bRead = call(d, #"{"id":4,"method":"tree","params":{"app":"Brave Browser","interactive":true}}"#)
    try expect(bRead.contains("Result"), "the other filter has not seen it yet either, so it too reports it: \(bRead)")
    let again = call(d, #"{"id":5,"method":"tree","params":{"app":"Brave Browser","interactive":true}}"#)
    try expect(again.contains(#""diff":"(no changes)""#), again)
  }

  test("an id seen under one filter can be acted on after a read under another") {
    let b = FakeBackend()
    let d = Dispatcher(backend: b)
    // depth:0 shows only the window; the default read shows the OK button (id 2).
    _ = call(d, #"{"id":1,"method":"tree","params":{"app":"Brave Browser","depth":0}}"#)
    let full = call(d, #"{"id":2,"method":"tree","params":{"app":"Brave Browser"}}"#)
    try expect(full.contains(#"2   button "OK""#), full)
    _ = call(d, #"{"id":3,"method":"tree","params":{"app":"Brave Browser","depth":0}}"#)
    let out = call(d, #"{"id":4,"method":"act","params":{"app":"Brave Browser","id":2,"action":"press"}}"#)
    try expect(out.contains(#""ok":true"#), "id 2 is in the registry and was seen under the default filter: \(out)")
    try expectEqual(b.acted.count, 1)
  }

  test("an action updates the baseline of the filter it ran with, and only that one") {
    let b = FakeBackend()
    let d = Dispatcher(backend: b)
    _ = call(d, #"{"id":1,"method":"tree","params":{"app":"Brave Browser"}}"#)
    _ = call(d, #"{"id":2,"method":"tree","params":{"app":"Brave Browser","interactive":true}}"#)
    b.snapshotsUntilChange = b.snapshotCount
    // The action snapshots under interactive:true and stores there.
    let act = call(d, #"{"id":3,"method":"act","params":{"app":"Brave Browser","id":2,"action":"press","interactive":true}}"#)
    try expect(act.contains("Result"), act)
    let b2 = call(d, #"{"id":4,"method":"tree","params":{"app":"Brave Browser","interactive":true}}"#)
    try expect(b2.contains(#""diff":"(no changes)""#), "interactive:true already saw the change via the action: \(b2)")
    let a2 = call(d, #"{"id":5,"method":"tree","params":{"app":"Brave Browser"}}"#)
    try expect(a2.contains("Result"), "the default filter has not: \(a2)")
  }
}
```

Add `runBaselineTests()` to `Sources/unbiased-ax-tests/main.swift` after `runDispatcherTests()`.

Check `FakeBackend` exposes `snapshotCount` (it is a `var` used inside `snapshot`; if `private`, make it internal). `b.acted` exists.

**Step 2: Run to verify failure**

Run: `cd <bridge tree> && swift build 2>&1 | tail -3 && swift run unbiased-ax-tests 2>&1 | grep -A6 'Baselines'`
Expected: the first test FAILS on `a2` ("(no changes)" expected; today the `interactive:true` read overwrote the single baseline, so the default read yields a diff of added/removed lines or a full tree) and the third FAILS with `no_such_element` on `act id 2`.

**Step 3: Implement**

In `Dispatcher.swift`:

```swift
  /// One diff baseline per (app, filter). A filter flip diffs against that
  /// filter's own last read; only a filter never read before gets a full tree.
  /// Measured 2026-09-08: 28 flips in one run, each a forced full tree, two
  /// compactions, nine minutes.
  private var baselines: [String: [String: Snapshot]] = [:]

  private static func filterKey(_ o: SnapshotOptions) -> String {
    "d\(o.maxDepth)m\(o.maxElements)i\(o.interactiveOnly)w\(o.webContent)"
  }
  private func baseline(_ app: String, _ o: SnapshotOptions) -> Snapshot? { baselines[app]?[Self.filterKey(o)] }
  private func store(_ app: String, _ o: SnapshotOptions, _ snap: Snapshot) {
    var perApp = baselines[app] ?? [:]
    perApp[Self.filterKey(o)] = snap
    baselines[app] = perApp
    remember(app, snap)
  }
  /// Every snapshot this app has been read under. Ids come from the per-app
  /// registry, so one seen under any filter is a real element.
  private func snapshots(_ app: String) -> [Snapshot] { Array((baselines[app] ?? [:]).values) }
```

Remove `private var last`. Then:
- `tree`: `let opts = options(p); let snap = try backend.snapshot(app: app, options: opts); defer { store(app, opts, snap) }`; `if let prev = baseline(app, opts), !full { diff } else { tree }`.
- `find`: `let opts = options(p); ...; store(app, opts, snap)`.
- `launch`: `store(app, opts, snap)` (it already computes `options(p)`; bind it once).
- `afterAction`: `let opts = options(p)` is already there; `if let prev = baseline(app, opts)`; the final diff uses `baseline(app, opts)`; replace `last[app] = snap; remember(app, snap)` with `store(app, opts, snap)`.
- `resolveId`: `guard !snapshots(app).isEmpty else { throw .noSuchElement(id) }`; `if snapshots(app).contains(where: { $0.nodes.contains { $0.id == id } }) { return id }`; the re-find matches against the MOST RECENT snapshot — keep a `private var latest: [String: Snapshot]` updated in `store` for that purpose (the re-find needs the current tree, whatever filter it was read with).
- `offers`: look the node up in `latest[app]` first, then any snapshot.
- `verifyValue`'s comment "leaves the baseline alone" still holds: it throws before `afterAction`.

**Step 4: Run all bridge tests**

Run: `swift build && swift run unbiased-ax-tests 2>&1 | tail -3`
Expected: `N passed, 0 failed` (N = 126 + 4). If an existing DispatcherTests case asserted that `find` or an action reset the baseline for a *different* filter, read it and decide: same-filter behaviour is unchanged, so such a test was encoding the bug.

**Step 5: Docs**

`docs/PROTOCOL.md` rule 2: replace "`find`, `launch` and every action reset the baseline." with: "Baselines are kept per filter (`depth`, `maxElements`, `interactive`, `web`): a read under a filter you have used before is a diff against that filter's last read; a filter never used is a full tree. `find`, `launch` and every action update the baseline of the filter they ran with. Ids are per app, not per filter — an id seen under any filter is actable." Also fix the parameter note at line ~132 ("use the same ones you read with, or the diff is full of `+`") — still true within a filter; leave.

**Step 6: Commit**

```bash
git add Sources docs/PROTOCOL.md
git commit -m "feat: one diff baseline per filter, so a filter flip is a diff and not a full tree

Measured 2026-09-08 on the Figma logo run: 28 web/interactive flips between
consecutive reads, each forcing the app to ask for the whole tree, ~185KB of
full trees, and two compactions that cost nine minutes. A flip now diffs
against that filter's own last read; only a filter never read is a full tree.
Ids stay valid across filters because they are per app.

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>"
```

---

### Task A2: `key escape` does not pay the shrink deadline

`escape` closes things: the honest final state IS a smaller tree. Measured: 8 escapes after Figma's colour picker, each 3.7s.

**Files:**
- Modify: `Sources/AXModel/Dispatcher.swift` (`key` case, `afterAction` signature + shrink test)
- Modify: `Sources/unbiased-ax-tests/DispatcherTests.swift` — find `runSettleTests()` (search `func runSettleTests`) and add one test there

**Step 1: Failing test** (inside `runSettleTests`, mirroring the existing "a tree that has only shrunk waits longer" test — read it first and reuse its fake knobs `shrunkUntilSnapshot`/`shrinkBy`):

```swift
  test("escape closing something is a settled shrink, not a transition: no long deadline") {
    let b = FakeBackend()
    b.shrunkUntilSnapshot = 1_000 // the tree stays shrunk: the picker is closed for good
    b.shrinkBy = 30
    let d = Dispatcher(backend: b)
    _ = call(d, #"{"id":1,"method":"tree","params":{"app":"Brave Browser"}}"#)
    let t0 = Date()
    let out = call(d, #"{"id":2,"method":"key","params":{"app":"Brave Browser","key":"escape"}}"#)
    let elapsed = Date().timeIntervalSince(t0)
    try expect(out.contains("removed"), out)
    try expect(elapsed < 2.0, "escape must settle on the ordinary deadline, took \(elapsed)s")
  }
```

**Step 2: Verify failure** — Run the suite; Expected: FAIL with "took ~3.5s".

**Step 3: Implement** — `afterAction(_ app:, _ p:, refound:, actionKey:, closing: Bool = false)`; in the loop `let shrank = !closing && lost >= Self.shrinkNodes && lost * 10 >= prev.nodes.count`. In the `key` case: `return try afterAction(app, p, refound: ..., closing: key == "escape")`. Comment: "escape's honest outcome is a smaller tree — the colour picker it closed is not coming back."

**Step 4: Verify pass** — full suite green.

**Step 5: Commit** — `fix: escape settles on the ordinary deadline; a closed panel is not a transition`.

---

### Task A3: `values` verb — read back a set of ids in one call

**Files:**
- Modify: `Sources/AXModel/Dispatcher.swift` (`methods`, new `case "values"`)
- Create: `Sources/unbiased-ax-tests/ValuesTests.swift`; register in `main.swift`
- Modify: `docs/PROTOCOL.md` methods table

**Step 1: Failing tests**

```swift
import AXModel

func runValuesTests() {
  print("values (read back a set of ids)")
  func call(_ d: Dispatcher, _ json: String) -> String { d.handle(line: json) }

  // After a batch the model re-read the app to check the fields it had just
  // written — 32 finds in one run. Hand it the values instead.
  test("values returns each id's current value with its role and title") {
    let b = FakeBackend()
    let d = Dispatcher(backend: b)
    _ = call(d, #"{"id":1,"method":"tree","params":{"app":"Brave Browser"}}"#) // Address field is id 3
    b.storedValues[3] = "b.com"
    let out = call(d, #"{"id":2,"method":"values","params":{"app":"Brave Browser","ids":[3]}}"#)
    try expect(out.contains(#""id":3"#) && out.contains(#""value":"b.com""#) && out.contains(#""role":"text field""#) && out.contains(#""title":"Address""#), out)
  }

  test("an id the app never showed comes back with a null value, not an error") {
    let d = Dispatcher(backend: FakeBackend())
    _ = call(d, #"{"id":1,"method":"tree","params":{"app":"Brave Browser"}}"#)
    let out = call(d, #"{"id":2,"method":"values","params":{"app":"Brave Browser","ids":[999]}}"#)
    try expect(out.contains(#""result""#) && out.contains(#""value":null"#), out)
  }

  test("values needs ids, at most 40 of them") {
    let d = Dispatcher(backend: FakeBackend())
    let none = call(d, #"{"id":1,"method":"values","params":{"app":"Brave Browser"}}"#)
    try expect(none.contains("bad_params"), none)
    let ids = (1...41).map(String.init).joined(separator: ",")
    let many = call(d, #"{"id":2,"method":"values","params":{"app":"Brave Browser","ids":[\#(ids)]}}"#)
    try expect(many.contains("bad_params") && many.contains("40"), many)
  }
}
```

**Step 2: Verify failure** — Expected: `unknown_method` on every call.

**Step 3: Implement**

```swift
  public static let maxValueIds = 40
  ...
    case "values":
      // Read back a handful of ids in one call. What each id described comes
      // from idMemory (role, title); the value is a fresh attribute read.
      // Measured 2026-09-08: 32 finds in one run existed to check fields a
      // batch had just written.
      guard let raw = p["ids"] as? [Int], !raw.isEmpty else { throw BridgeError.badParams("Pass ids: a non-empty list of element ids.") }
      guard raw.count <= Self.maxValueIds else { throw BridgeError.badParams("\(raw.count) ids is too many (max \(Self.maxValueIds)).") }
      var out: [[String: Any]] = []
      for id in raw {
        let attrs = idMemory[app]?[id]
        let v = try? backend.value(app: app, id: id)
        out.append(["id": id, "role": attrs?.role ?? NSNull(), "title": attrs?.title ?? NSNull(), "value": (v ?? nil) ?? NSNull()])
      }
      return ["values": out]
```

Add `"values"` to `methods`. Note `idMemory` only holds identifiable nodes (title or value non-empty) — fine for fields.

**Step 4: Verify pass. Step 5: PROTOCOL.md** table row: `| values | app, ids:[Int] (≤40) | {values:[{id, role, title, value}]} — the current value of each id, one attribute read each, no tree walk; value is null when the element exposes none or the id is unknown |`.

**Step 6: Commit** — `feat: values reads back a set of ids in one call`.

**Step 7: Build the bundle** so a live app can use it: `make bundle` (writes `dist/` in this tree). Do not merge.

---

## Part B — app

### Task B1: A filter switch no longer forces a full tree

**Files:**
- Modify: `src/main/index.ts` `case "computer_app_state"` (~2506–2560): delete `const switched = ...` and use `full: a.full === true`
- Modify: `src/main/ax-bridge.ts`: delete `axFilterSwitched` (keep `axReadOptsFrom`, `AX_DEFAULT_READ_OPTS`)
- Modify: `src/main/ax-bridge.test.ts`: delete the `axFilterSwitched` test block (~:495–511) and the import; add a source-text guard

**Step 1: Failing test** (in `ax-bridge.test.ts`, near the other `readFileSync(index.ts)` guards):

```ts
test("a read that changes the filter is a diff, not a forced full tree (the bridge keeps one baseline per filter)", () => {
  const src = readFileSync(join(__dirname, "index.ts"), "utf8");
  assert.ok(!src.includes("axFilterSwitched"), "the app no longer decides this; the bridge diffs against the filter's own baseline");
  assert.ok(src.includes("full: a.full === true,"), "full is the model's explicit ask and nothing else");
});
```

**Step 2: Verify failure. Step 3: Implement** the deletions; the comment above `full:` becomes: "the bridge holds one baseline per filter, so a filter change is a diff against that filter's own last read — full is only ever the model's explicit ask." Run `npm run typecheck`.

**Step 4: `npm test` green. Step 5: Commit** — `fix(ax): a filter change is a diff, not a full tree — the bridge keeps a baseline per filter`.

---

### Task B2: A batch reads back every field it touched

**Files:**
- Modify: `src/main/ax-bridge.ts`: add `touchedFieldIds(steps)`, `renderFieldValues(values)`, extend `summarizeBatch` with `fields?: string`, replace the caveat text
- Modify: `src/main/index.ts` `case "computer_do"` steps path: after the closing tree read, call `values`
- Modify: `src/main/ax-bridge.test.ts`

**Step 1: Failing tests**

```ts
test("a batch names the fields it touched so they can be read back", () => {
  const steps: BatchStep[] = [
    { do: "pointer", id: 88, clicks: 2, waitMs: 0 }, { do: "key", key: "a", modifiers: ["command"], waitMs: 0 },
    { do: "type", text: "460", waitMs: 0 }, { do: "key", key: "return", waitMs: 0 },
    { do: "set_value", id: 101, text: "360", waitMs: 0 }, { do: "type", text: "x", id: 88, waitMs: 0 },
    { do: "press", id: 5, waitMs: 0 }, { do: "read", waitMs: 0 },
  ];
  assert.deepEqual(touchedFieldIds(steps), [88, 101], "pointer, set_value and type-with-id are field edits; press and read are not; ids are unique in first-seen order");
  assert.deepEqual(touchedFieldIds(Array.from({ length: 20 }, (_, i) => ({ do: "set_value", id: i, text: "1", waitMs: 0 }) as BatchStep)).length, 12, "capped at 12");
});

test("field values render one line per id, with what the bridge knows about it", () => {
  const out = renderFieldValues([
    { id: 88, role: "incrementor", title: "X-position", value: "460" },
    { id: 101, role: "text field", title: "Width", value: "360" },
    { id: 7, role: null, title: null, value: null },
  ]);
  assert.equal(out, 'Fields now:\n#88 incrementor "X-position" = 460\n#101 text field "Width" = 360\n#7 = (no value)');
});

test("a multi-step batch reports the fields it read back instead of a caveat about presses", () => {
  const ran = ["step 1 (set_value #88 = \"550\")", "step 2 (press #12)"];
  const out = summarizeBatch({ ran, failed: null, remaining: 0, diff: "~ 12 button", unwatched: true, fields: 'Fields now:\n#88 text field "Width" = 550' });
  assert.ok(out.includes("Only the closing diff was watched"), out);
  assert.ok(!out.includes("not watched individually") && !out.includes("Every value written was read back"), out);
  assert.ok(out.endsWith('\nFields now:\n#88 text field "Width" = 550'), out);
  const one = summarizeBatch({ ran: [ran[0]], failed: null, remaining: 0, diff: "~ 88", unwatched: true });
  assert.ok(!one.includes("closing diff"), "a single step settled on its own: no caveat");
});
```

Update the existing "a multi-step batch does not claim more than it watched" test to the new wording (or delete it in favour of the above).

**Step 2: Verify failure. Step 3: Implement**

```ts
/** The ids a batch wrote into: set_value, type aimed at an id, and pointer
 *  (the click that starts the four-step stepper recipe). Presses are not
 *  field edits. Unique, first-seen order, capped — a batch of thirty edits
 *  reads back the first dozen, which is every field on one Figma shape. */
export const MAX_FIELDS_READ_BACK = 12;
export function touchedFieldIds(steps: BatchStep[]): number[] {
  const ids: number[] = [];
  for (const st of steps) {
    const id = st.do === "set_value" || st.do === "pointer" ? st.id : st.do === "type" ? st.id : undefined;
    if (typeof id === "number" && !ids.includes(id)) ids.push(id);
    if (ids.length >= MAX_FIELDS_READ_BACK) break;
  }
  return ids;
}

export type FieldValue = { id: number; role: string | null; title: string | null; value: string | null };
export function renderFieldValues(values: FieldValue[]): string {
  const lines = values.map((v) => {
    const what = [v.role, v.title ? JSON.stringify(v.title) : null].filter(Boolean).join(" ");
    return `#${v.id}${what ? ` ${what}` : ""} = ${v.value ?? "(no value)"}`;
  });
  return `Fields now:\n${lines.join("\n")}`;
}
```

`summarizeBatch`: add `fields?: string` to opts; caveat for `unwatched && ran.length > 1` becomes `"Only the closing diff was watched; the field values below were read back afterwards."` when `fields` is present, else `"Only the closing diff was watched."`; append `\n${opts.fields}` at the very end when present (after the diff / no-change sentence).

In `index.ts` `computer_do` after the closing `tree`:

```ts
        let fields: string | undefined;
        const touched = touchedFieldIds(steps);
        if (touched.length) {
          try {
            const r = await ax.request("values", { app: appName, ids: touched }, 3_000);
            const values = Array.isArray(r.values) ? (r.values as FieldValue[]) : [];
            if (values.length) fields = renderFieldValues(values);
          } catch {
            // an older bridge has no `values`; the diff still stands
          }
        }
```

and pass `fields` to `summarizeBatch`. Import `touchedFieldIds`, `renderFieldValues`, `FieldValue`. The `computer_do` description's sentence "Every set_value is read back, so a field that kept its old text…" becomes "After the batch, every field it touched is read back and listed, so you do not need to read the app to check a value."

**Step 4: `npm test` + typecheck green. Step 5: Commit** — `feat(ax): a batch reads back every field it touched, so nobody has to read the app to check one`.

---

### Task B3: The two reproachful sentences become facts

**Files:** `src/main/ax-bridge.ts` (`ACTION_NO_CHANGE_SENTENCE`), `src/main/ax-bridge.test.ts`

**Step 1: Failing test**

```ts
// Rollout 01a081a0 (2026-09-08): with no human in the loop, three model turns
// opened "You're right — let me stop…" in direct reply to this sentence and to
// the batch caveat, and each began a re-plan. A tool result is evidence, not
// a reviewer; it says what happened and what else is available.
test("tool text states facts and options, never scolds or cites past runs", () => {
  for (const s of [ACTION_NO_CHANGE_SENTENCE, summarizeBatch({ ran: ["a", "b"], failed: null, remaining: 0, diff: "~ 1", unwatched: true })]) {
    assert.ok(!/do not|don't|never|in the last run|cost \w+ turns|retries/i.test(s), s);
  }
});
```

**Step 2: Verify failure. Step 3: Implement**

```ts
export const ACTION_NO_CHANGE_SENTENCE =
  "The app accepted the action and nothing in the tree changed while the bridge waited. The same action again would do the same. Other paths that reach a control: the keyboard (arrows and return choose from a list, escape closes), or a menu bar item — both are in the tree.";
```

Check `renderActionResult` tests (`:816`) still pass — they reference the constant. Check `parkedNextCall` and `parkedReadNote` are untouched (they are literal calls, and out of this task's scope).

**Step 4: Green. Step 5: Commit** — `fix(ax): the no-change reply states facts and options; it stopped reading as a reviewer`.

---

### Task B4: `checkpoint.ts` — the pure half of the compaction checkpoint

**Files:**
- Create: `src/main/checkpoint.ts`
- Create: `src/main/checkpoint.test.ts`

**Step 1: Failing tests**

```ts
import { test } from "node:test";
import assert from "node:assert/strict";
import { checkpointPath, validateCheckpointNotes, renderCheckpoint, pushFact, checkpointDue, checkpointGateText, checkpointPreamble, isGatedTool, CHECKPOINT_PERCENT, MAX_CHECKPOINT_NOTES, MAX_LEDGER, CHECKPOINT_TOOLS, type LedgerEntry } from "./checkpoint";

test("the checkpoint lives in ./memories under the conversation's cwd, named by the root thread", () => {
  assert.equal(checkpointPath("/Users/n/Unbiased", "01a0-root"), "/Users/n/Unbiased/memories/01a0-root.md");
});

test("notes must be decisions and measured facts: short, no trees, no images", () => {
  assert.deepEqual(validateCheckpointNotes("palette: #10100F bg; top ring #FC7864 at (256,228) 512x512 DONE"), { ok: true });
  assert.match((validateCheckpointNotes("") as { ok: false; error: string }).error, /empty/);
  assert.match((validateCheckpointNotes("x".repeat(MAX_CHECKPOINT_NOTES + 1)) as { ok: false; error: string }).error, /characters/);
  const tree = Array.from({ length: 6 }, (_, i) => `${i + 10}     button "Pad ${i}" {press}`).join("\n");
  assert.match((validateCheckpointNotes(`decisions\n${tree}`) as { ok: false; error: string }).error, /element tree/);
  assert.match((validateCheckpointNotes("look: data:image/jpeg;base64,/9j/4AAQ").error ?? "", /image/);
  assert.match((validateCheckpointNotes("A".repeat(240)) as { ok: false; error: string }).error, /image|encoded/);
});

test("the ledger keeps the newest facts, clipped, and never grows past its cap", () => {
  const ledger: LedgerEntry[] = [];
  for (let i = 0; i < MAX_LEDGER + 5; i++) pushFact(ledger, `fact ${i} ${"y".repeat(300)}`, `15:${String(i % 60).padStart(2, "0")}:00`);
  assert.equal(ledger.length, MAX_LEDGER);
  assert.ok(ledger[0].text.startsWith("fact 5 "), "the oldest five were dropped");
  assert.ok(ledger[0].text.length <= 200);
});

test("the rendered file has the model's section and the app's section, and says when and why it was written", () => {
  const md = renderCheckpoint({ root: "r1", notes: "top ring done; bottom next", facts: [{ at: "15:44:20", text: "Figma #2582 \"Width\" = 512" }], savedAt: "2026-09-08T15:45:00Z", percent: 62, compactions: 0 });
  assert.ok(md.startsWith("# Working memory"), md);
  assert.ok(md.includes("62% of the context window") && md.includes("compactions so far: 0"), md);
  assert.ok(md.includes("## Decisions and plan (written by the model)\ntop ring done; bottom next"), md);
  assert.ok(md.includes("## Measured facts (recorded by the app)\n- 15:44:20 Figma #2582 \"Width\" = 512"), md);
  const empty = renderCheckpoint({ root: "r1", notes: null, facts: [], savedAt: "t", percent: 61, compactions: 1 });
  assert.ok(empty.includes("(no notes written yet)") && empty.includes("(none yet)"), empty);
});

test("the gate opens once per cycle, at the threshold, until a checkpoint is saved", () => {
  assert.equal(checkpointDue({ percent: CHECKPOINT_PERCENT - 1, savedThisCycle: false, gateUsed: false }), false);
  assert.equal(checkpointDue({ percent: CHECKPOINT_PERCENT, savedThisCycle: false, gateUsed: false }), true);
  assert.equal(checkpointDue({ percent: 90, savedThisCycle: true, gateUsed: false }), false, "saved: nothing to ask");
  assert.equal(checkpointDue({ percent: 90, savedThisCycle: false, gateUsed: true }), false, "asked once already: the second action goes through");
  assert.equal(checkpointDue({ percent: null, savedThisCycle: false, gateUsed: false }), false);
});

test("the gate text is a literal call, says the action did not run, and says what belongs in it", () => {
  const t = checkpointGateText(64, "/Users/n/Unbiased/memories/r1.md");
  assert.ok(t.includes("64%") && t.includes("not run"), t);
  assert.ok(t.includes('checkpoint_save {"notes":"'), t);
  assert.ok(/decisions|measured/i.test(t) && /not .*tree|no tree/i.test(t), t);
  assert.ok(t.includes("then send the action again"), t);
});

test("only actions are gated; reads and the checkpoint itself are not", () => {
  for (const t of ["computer_press", "computer_set_value", "computer_press_key", "computer_do", "computer_pointer", "computer_act", "computer_scroll_view", "computer_launch", "computer_raise"]) assert.equal(isGatedTool(t), true, t);
  for (const t of ["computer_app_state", "computer_apps", "computer_app_screenshot", "computer_screenshot", "checkpoint_save", "memory_save", "browser_click"]) assert.equal(isGatedTool(t), false, t);
});

test("the preamble frames the file so it cannot be mistaken for tool output, and is capped", () => {
  const p = checkpointPreamble("# Working memory\nstuff");
  assert.ok(p.startsWith("=== Working memory you saved before the context was summarized"), p);
  assert.ok(p.endsWith("=== end ==="), p);
  assert.ok(checkpointPreamble("x".repeat(40_000)).length < 17_000);
});

test("checkpoint_save is declared with notes as its only required field", () => {
  assert.equal(CHECKPOINT_TOOLS.length, 1);
  const t = CHECKPOINT_TOOLS[0] as { name: string; inputSchema: { required: string[]; properties: Record<string, unknown> } };
  assert.equal(t.name, "checkpoint_save");
  assert.deepEqual(t.inputSchema.required, ["notes"]);
  assert.ok("notes" in t.inputSchema.properties);
});
```

**Step 2: Verify failure** (`Cannot find module './checkpoint'`). **Step 3: Implement**

```ts
import { join } from "node:path";

/** A working-memory checkpoint that survives context compaction.
 *
 *  Measured 2026-09-08 (Figma logo run, 124,518-token window): two automatic
 *  compactions at 15:40 and 15:49 cost 3.4 minutes of dead time and about 5.5
 *  minutes of re-orientation — after the second the model no longer knew it
 *  had drawn its shapes rather than duplicated them and spent three minutes on
 *  a duplicate that could not be seen. The engine compacts on its own and
 *  tells the app only afterwards, so "before" has to be pre-emptive: at
 *  CHECKPOINT_PERCENT the first ACTION is held once and the model is handed
 *  the literal call to save its decisions; the app records measured facts on
 *  its own regardless; and the first tool result after a compaction carries
 *  the file back. Decisions and measured facts only — trees and screenshots
 *  are refused, because they are exactly what filled the window. */
export const CHECKPOINT_PERCENT = 60;
export const MAX_CHECKPOINT_NOTES = 4_000;
export const MAX_LEDGER = 80;
export const MAX_FACT_CHARS = 200;
export const MAX_CHECKPOINT_PREAMBLE = 16_000;

export type LedgerEntry = { at: string; text: string };

export function checkpointPath(cwd: string, rootThreadId: string): string {
  return join(cwd, "memories", `${rootThreadId}.md`);
}

const ELEMENT_LINE = /^\s*\d+\s+[a-z][a-z ]*(?: "|\s=|\s\[|\s\{|$)/;
export function validateCheckpointNotes(notes: string): { ok: true } | { ok: false; error: string } {
  const t = notes.trim();
  if (!t) return { ok: false, error: "notes is empty. Write the decisions made so far and the facts measured (numbers, names, colours, what is done and what is next)." };
  if (t.length > MAX_CHECKPOINT_NOTES) return { ok: false, error: `notes is ${t.length} characters; at most ${MAX_CHECKPOINT_NOTES}. Keep decisions and measured facts, drop everything that can be read again from the app.` };
  const treeLines = t.split("\n").filter((l) => ELEMENT_LINE.test(l)).length;
  if (treeLines >= 5) return { ok: false, error: `notes contains ${treeLines} element tree lines. The tree can be read again; write what you decided and what you measured instead.` };
  if (/data:image\//.test(t) || /[A-Za-z0-9+/]{200,}/.test(t)) return { ok: false, error: "notes contains image or encoded data. A screenshot cannot be remembered this way; write what it showed." };
  return { ok: true };
}

export function pushFact(ledger: LedgerEntry[], text: string, at: string = new Date().toISOString().slice(11, 19)): void {
  const clipped = text.length > MAX_FACT_CHARS ? `${text.slice(0, MAX_FACT_CHARS - 1)}…` : text;
  ledger.push({ at, text: clipped });
  if (ledger.length > MAX_LEDGER) ledger.splice(0, ledger.length - MAX_LEDGER);
}

export function renderCheckpoint(c: { root: string; notes: string | null; facts: LedgerEntry[]; savedAt: string; percent: number; compactions: number }): string {
  return [
    `# Working memory — conversation ${c.root}`,
    `Saved ${c.savedAt} at ${c.percent}% of the context window; compactions so far: ${c.compactions}.`,
    "",
    "## Decisions and plan (written by the model)",
    c.notes?.trim() || "(no notes written yet)",
    "",
    "## Measured facts (recorded by the app)",
    c.facts.length ? c.facts.map((f) => `- ${f.at} ${f.text}`).join("\n") : "(none yet)",
    "",
  ].join("\n");
}

export function checkpointDue(s: { percent: number | null; savedThisCycle: boolean; gateUsed: boolean }): boolean {
  return s.percent !== null && s.percent >= CHECKPOINT_PERCENT && !s.savedThisCycle && !s.gateUsed;
}

export function checkpointGateText(percent: number, path: string): string {
  return (
    `The context is at ${percent}%; it will be summarized soon and details not written down are lost. This action was not run. ` +
    `First save your working memory: checkpoint_save {"notes":"<decisions made, plan, measured numbers/names/colours, what is done, what is next>"} — ` +
    `decisions and measured facts only, no tree lines and no images (it is written to ${path} and handed back to you after the summary). Then send the action again.`
  );
}

export function checkpointPreamble(markdown: string): string {
  const body = markdown.length > MAX_CHECKPOINT_PREAMBLE - 200 ? `${markdown.slice(0, MAX_CHECKPOINT_PREAMBLE - 220)}\n…(truncated)` : markdown;
  return `=== Working memory you saved before the context was summarized (read it, then continue) ===\n${body}\n=== end ===`;
}

const GATED = new Set(["computer_press", "computer_set_value", "computer_press_key", "computer_scroll_view", "computer_act", "computer_do", "computer_pointer", "computer_launch", "computer_raise"]);
export function isGatedTool(tool: string): boolean { return GATED.has(tool); }

export const CHECKPOINT_TOOLS = [
  {
    type: "function",
    name: "checkpoint_save",
    description:
      "Save your working memory for THIS conversation so it survives the context being summarized: the decisions you have made, the plan, the numbers, names and colours you measured, what is done and what is next. " +
      "It replaces the previous checkpoint, so write everything you would need to resume. Decisions and measured facts only — element trees and screenshots are refused; they can be read again. " +
      "Call it when a tool result asks you to, and whenever you finish a stage of a long task. The saved file is handed back to you automatically after a summary.",
    inputSchema: {
      type: "object",
      properties: { notes: { type: "string", description: `Markdown, at most ${MAX_CHECKPOINT_NOTES} characters.` } },
      required: ["notes"],
    },
  },
];
```

**Step 4: Green. Step 5: Commit** — `feat: checkpoint — the pure half of a working memory that survives compaction`.

---

### Task B5: Wire the checkpoint into the main process

**Files:** `src/main/index.ts`; `src/main/ax-bridge.test.ts` (source-text guards)

**Step 1: Failing test** (source-text, the codebase's pattern for index.ts wiring):

```ts
test("the checkpoint is wired: declared, routed, gated before actions, written at the threshold, replayed after compaction", () => {
  const src = readFileSync(join(__dirname, "index.ts"), "utf8");
  assert.ok(src.includes("...CHECKPOINT_TOOLS"), "declared to every thread");
  assert.ok(src.includes('tool.startsWith("checkpoint_")') && src.includes("handleCheckpointToolCall("), "routed by prefix");
  assert.ok(src.includes("isGatedTool(tool) && checkpointDue("), "the first action past the threshold is held once");
  assert.ok(src.includes("ctxPercent.set(String(params.threadId)"), "the app tracks context occupancy per thread");
  assert.ok(src.includes("checkpointReplayDue.add(") && src.includes("checkpointPreamble("), "the file comes back on the first tool result after a compaction");
  assert.ok(src.includes("pushFact("), "measured facts are recorded by the app");
});
```

**Step 2: Verify failure. Step 3: Implement**, in `index.ts`:

1. Imports from `./checkpoint`: `CHECKPOINT_TOOLS, checkpointPath, validateCheckpointNotes, renderCheckpoint, pushFact, checkpointDue, checkpointGateText, checkpointPreamble, isGatedTool, type LedgerEntry`.
2. State near `axSkillSent` (~4204):
   ```ts
   const ctxPercent = new Map<string, number>();
   type CheckpointCycle = { savedThisCycle: boolean; gateUsed: boolean; compactions: number; notes: string | null };
   const checkpointCycles = new Map<string, CheckpointCycle>();
   const checkpointLedger = new Map<string, LedgerEntry[]>();
   const checkpointReplayDue = new Set<string>();
   function checkpointCycle(root: string): CheckpointCycle { let c = checkpointCycles.get(root); if (!c) { c = { savedThisCycle: false, gateUsed: false, compactions: 0, notes: null }; checkpointCycles.set(root, c); } return c; }
   function checkpointFile(root: string): string { return checkpointPath(threadCwds.get(root) ?? defaultChatDir(), root); }
   function writeCheckpoint(root: string): string {
     const c = checkpointCycle(root); const file = checkpointFile(root);
     mkdirSync(dirname(file), { recursive: true });
     writeFileSync(file, renderCheckpoint({ root, notes: c.notes, facts: checkpointLedger.get(root) ?? [], savedAt: new Date().toISOString(), percent: ctxPercent.get(root) ?? 0, compactions: c.compactions }));
     return file;
   }
   function recordFact(threadId: string | null, text: string): void { const root = rootThreadOf(threadId); const l = checkpointLedger.get(root) ?? []; pushFact(l, text); checkpointLedger.set(root, l); }
   ```
   (`mkdirSync`, `dirname`, `writeFileSync` are already imported in index.ts; verify.)
3. `thread/tokenUsage/updated` handler: after computing `usage`, `if (usage.percent !== null) { const root = rootThreadOf(String(params.threadId)); ctxPercent.set(String(params.threadId), usage.percent); ctxPercent.set(root, usage.percent); const c = checkpointCycle(root); if (checkpointDue({ percent: usage.percent, savedThisCycle: c.savedThisCycle, gateUsed: c.gateUsed }) && !c.thresholdWritten) { c.thresholdWritten = true; try { writeCheckpoint(root); axLog(`checkpoint: wrote app facts at ${usage.percent}% for ${root}`); } catch {} } }` — add `thresholdWritten: boolean` to the cycle type (reset with the cycle).
4. `contextCompaction` completed branch: `if (threadId) { const root = rootThreadOf(threadId); const c = checkpointCycle(root); c.compactions += 1; c.savedThisCycle = false; c.gateUsed = false; c.thresholdWritten = false; checkpointReplayDue.add(root); axLog(`checkpoint: compaction ${c.compactions} on ${root}; replay armed`); }`.
5. `threadDynamicTools`: `...CHECKPOINT_TOOLS,` after `...MEMORY_TOOLS,`.
6. Dispatch: `tool.startsWith("checkpoint_") ? handleCheckpointToolCall(tool, args, approvalThread) :` before the `memory_` branch. In the `.then` chain, BEFORE the skill step, add a replay step:
   ```ts
   .then((response) => {
     const root = rootThreadOf(approvalThread);
     if (!checkpointReplayDue.has(root)) return response;
     checkpointReplayDue.delete(root);
     try {
       const file = checkpointFile(root);
       if (!existsSync(file)) return response;
       const md = readFileSync(file, "utf8");
       axLog(`checkpoint: replayed ${md.length} chars after compaction (${tool})`);
       return prependSkill(response, checkpointPreamble(md));
     } catch { return response; }
   })
   ```
   (`prependSkill` is the generic "unshift one inputText item" helper — reuse it.)
7. `handleCheckpointToolCall`:
   ```ts
   async function handleCheckpointToolCall(tool: string, rawArgs: unknown, threadId: string | null): Promise<DynamicToolResponse> {
     const text = (t: string, ok: boolean): DynamicToolResponse => ({ contentItems: [{ type: "inputText", text: t }], success: ok });
     if (tool !== "checkpoint_save") return text(`Unknown tool ${tool}`, false);
     const notes = (rawArgs as { notes?: unknown })?.notes;
     if (typeof notes !== "string") return text("notes is required: the decisions and measured facts to keep.", false);
     const v = validateCheckpointNotes(notes);
     if (!v.ok) return text(v.error, false);
     const root = rootThreadOf(threadId); const c = checkpointCycle(root);
     c.notes = notes.trim(); c.savedThisCycle = true;
     try { const file = writeCheckpoint(root); const facts = checkpointLedger.get(root)?.length ?? 0;
       axLog(`checkpoint: saved ${c.notes.length} chars of notes + ${facts} facts to ${file}`);
       return text(`Saved working memory to ${file} (${c.notes.length} characters of notes, ${facts} recorded facts). It is handed back to you automatically after the next summary.`, true);
     } catch (err) { return text(`Could not write the checkpoint: ${String(err)}`, false); }
   }
   ```
8. `handleAxCall`: after the consent block and `remember` definition, before `switch`: 
   ```ts
   const cycle = checkpointCycle(root);
   if (isGatedTool(tool) && checkpointDue({ percent: ctxPercent.get(root) ?? null, savedThisCycle: cycle.savedThisCycle, gateUsed: cycle.gateUsed })) {
     cycle.gateUsed = true;
     axLog(`checkpoint: held ${tool} at ${ctxPercent.get(root)}% until notes are saved`);
     return axText(checkpointGateText(ctxPercent.get(root) ?? 0, checkpointFile(root)), false);
   }
   ```
9. Facts (measured only): in `computer_do` after the values read-back: `for (const v of values) recordFact(threadId, `${appName} #${v.id}${v.title ? ` "${v.title}"` : ""} = ${v.value ?? "(no value)"}`)`; in `computer_pointer` after `at`: `if (at.length) recordFact(threadId, `${appName} pointer #${a.id} ${hold ? "drag" : "click"} landed ${at.map((q) => `(${q.x},${q.y})`).join(" ")}`)`; in `computer_set_value` single call success: `recordFact(threadId, `${appName} set #${a.id} = ${JSON.stringify(text)}`)`; in `computer_launch`: `recordFact(threadId, `${appName} launched: ${launchOutcome(tree)}`)`; in `computer_raise`: `recordFact(threadId, `${appName} raised (the model asked)`)`.

Run `npm run typecheck` after each edit.

**Step 4: `npm test` + typecheck green. Step 5: Commit** — `feat: a working-memory checkpoint that is asked for before compaction and handed back after it`.

---

### Task B6: The skill points at the mechanism

**Files:** `resources/skills/computer-use/SKILL.md` (section "## Keep your measurements in a file", lines ~222–241); `src/main/computer-use.test.ts` (needles)

**Step 1: Failing test** — add `"checkpoint_save"` to the needle list in "the computer-use skill carries the findings that cost the most to learn".

**Step 2: Verify failure. Step 3: Rewrite the section:**

```markdown
## Your working memory survives a summary only if you save it

A long conversation gets summarized, and the summary keeps the plan and drops
the numbers — measured, a run re-derived the same palette three times. So
there is a checkpoint.

- **Save it with `checkpoint_save`** whenever you finish a stage, and whenever
  a tool result tells you the context is nearly full. Write decisions, the
  plan, measured numbers, names and colours, what is done and what is next. It
  replaces the previous checkpoint, so write everything you would need to
  resume. Element trees and screenshots are refused: they can be read again.
- **The app records measured facts on its own** — every field a batch read
  back, where pointer clicks landed, what launched — into the same file.
- **After a summary the file is handed back to you** with your next tool
  result. Read it before you act; it is the ground truth for what you already
  finished, and the tree says whether it is still there.

The first action you send past the threshold is held once until you have saved:
the reply carries the exact call. Save, then send the action again.
```

Keep the existing example of what a good note looks like (palette, shapes DONE/not started). Keep every guarded needle.

**Step 4: Green. Step 5: Commit** — `docs(skill): working memory is a checkpoint the app asks for and hands back`.

---

### Task B7: Verify end to end, both trees

1. Bridge: `make test` → all green; `make bundle` → `dist/unbiased-ax` answers `{"id":1,"method":"values","params":{"app":"Finder","ids":[1]}}` with `values` (or `not_trusted` from a shell, which still proves the verb exists — `unknown_method` would not).
2. App: `npm test` (expect 240 + new), `npm run typecheck`.
3. Report: per-task commits on both branches, test counts, and that nothing is merged or pushed. A live Figma re-run needs the dev app started from the app tree with `UNBIASED_AX_DIR=<bridge tree>/dist UNBIASED_AX_DEBUG=1 npm run dev` (plus `UNBIASED_ENGINE_DIR=/Users/naveen/Projects/Work/unbiased-app-engine/dist/bundle` from a worktree) — the user's call.
