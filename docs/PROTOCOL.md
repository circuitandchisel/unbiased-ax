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
2. **An id the app rebuilt is re-found.** Ids are element identities, so a
   control torn down and rebuilt gets a new one. When an action names an id the
   latest snapshot no longer has, the bridge matches what that id described
   (role, title, value) against the snapshot: exactly one match is acted on and
   the result carries `refoundId` and a `note`. Zero matches, several matches,
   or a control with neither title nor value is refused as before.
3. **The same action, after it changed nothing, is refused once.** An action
   that was accepted and moved nothing cannot move anything on a second try, so
   the identical verb on the identical element is declined with a pointer at a
   different path. An action that DID change something may be repeated freely,
   and `key` is exempt entirely: an app that does not expose its selection
   makes every arrow key look like a no-op.
4. **`tree` returns a diff after the first call** for an app, unless
   `"full":true`. `~` changed, `+` added, `- removed: 2-4, 9`. `(no changes)`
   when nothing moved. Baselines are kept per filter (`depth`, `maxElements`, `interactive`, `web`): a read under a filter used before is a diff against that filter's last read; a filter never used is a full tree. `find`, `launch` and every action update the baseline of the filter they ran with. Ids are per app, not per filter — an id seen under any filter is actable.
5. **Every action waits for the app to react** before reporting, unless it says
   `"settle": false`: at least 0.6s,
   at most 1.5s. An action that changes nothing pays the full 1.5s. A tree that
   has lost at least ten nodes AND a tenth of itself since the action is
   treated as in transition (a result list that collapsed before its place card
   rendered) and waits up to 3.5s for what replaces it. Both thresholds matter:
   a bare "fewer nodes" test also fired on every Figma selection change and
   closing panel, where nothing more was coming, and cost 94 seconds of waiting
   in one task. `key escape` is exempt: a smaller tree is its final state, so
   it settles on the ordinary deadline. The result carries `waitedMs`. The first action on an app
   never read has no baseline: it returns at once, and `diff` is the full tree.

## Spaces

`hello` reports `crossSpace`. When true, windows on another Space are in the
tree and are read, found and acted on like any other — `scroll` excepted: it is
the only verb that uses screen coordinates, and whether an off-Space window
scrolls its content is unconfirmed. `windows` marks them
`[other Space]` and `offscreen` counts them. One hint remains in this world:
when the tree has no window and the window server still lists some, the read
says they could not be read yet and to read again — never to raise. `offscreen`
is then a count of what the window server lists, not of what was mapped.
Nothing needs raising to be read.

When false — the private path has not passed its self-check on this machine, or
the process is not yet trusted — only the current Space is readable, and reads
carry a `hint` saying whether to `raise` when any window is elsewhere. With it
false, `offscreen` is every window the window server knows for the app that is
not on screen — other Spaces, hidden and minimized alike — and it is inflated by
system windows that are not windows at all; treat it as a signal, not a count.
The verdict is decided on the first trusted call that finds an app to witness
with — retried at most every 30s until then — and can turn from false to true in
a long-lived bridge; call `hello` again to see it. Deciding it is budgeted at
five seconds, paid by the first trusted call; one slow app can stretch it by a
single read.

With Stage Manager on, macOS parks every inactive app's window into the side strip as a thumbnail (measured: 108x104 while the Accessibility API reports 1024x768). A thumbnail does not hit-test, so `press` on list rows, card buttons and tabs is accepted and does nothing, and `screenshot` of that window is blank. Posted keys and menu bar items are unaffected. An action that changes nothing in that state carries a `hint` saying so and naming the paths that work. `windows` marks such a window `[parked]` and sets `parked: true`, so the state is visible before anything is tried. Readable and interactable are separate properties here and only the second one fails: the tree is exact, the presses are not. One flag says that, and a caller wanting the distinction reads it as "readable, since you have a tree at all, and not interactable while `parked` is true". And because guidance was measured to lose — the hint, the raise description and the bundled skill all said not to raise, and six runs raised anyway — the FIRST `raise` while a window is parked is refused, naming the keyboard route instead. The decision is the window's state at that moment, not what the previous action did: an earlier version armed on a dead action and disarmed on a successful one, so the keyboard workaround switched the guard off at the moment it worked. Asking a second time goes through, and un-parking re-arms it for the next episode, so a caller that means it is not blocked; only the reflex is.

`screenshot` photographs a window on another Space as well (measured: Maps' UI came back in 72ms with Brave still frontmost). What the app does not draw while hidden is black in the picture; controls and text are not.

A zero width or height hides an element only when it has no children. A
container that reports zero and still has children is a layout wrapper, and its
children are hoisted to its depth: measured, Figma labels a group "Right
sidebar" at 1470x0 whose child panel is a real 241x885, and dropping that
subtree removed every inspector field in the app — position, size, opacity and
every fill swatch — from every tree ever taken of it, while "Left sidebar" at
57x885 came through. Genuinely hidden content reports zero for its children
too, so it still disappears, one node at a time. The check runs before the
depth cap, which is why a larger `depth` never recovered any of it.

## Methods

| method | params | result |
|---|---|---|
| `hello` | — | `{name, protocolVersion, trusted, crossSpace}` — works without Accessibility |
| `apps` | — | `{apps:[{pid,name,bundleId,frontmost}]}` — works without Accessibility |
| `windows` | `app` | `{windows:[{id,title,x,y,width,height,minimized,focused,onSpace}], text, offscreen, hint?}` — one line per window |
| `tree` | `app`, `depth?`(14), `maxElements?`(1500), `interactive?`, `web?` (Chromium page content, opt-in, sticky for that process), `geometry?`, `full?` | `{tree|diff, count, truncated, offscreen, hint?}` |
| `find` | `app`, `role?` (exact), `title?` (substring, also matches value), plus the `tree` options | `{matches:[lines], count, offscreen, hint?}` — a search, not a dump |
| `act` | `app`, `id`, `action` (`press`, `confirm` — commits a text field —, `raise`, `show menu`, `focus`, or any action shown in braces), `keepFront?` (default false) | `{ok, diff}` |
| `setValue` | `app`, `id`, `value`, `keepFront?` (default false), `verify?` (default true) | `{ok, diff}` — focuses the element first; it does not commit — follow with `key return` for an omnibox. The value is read back unless `verify` is false |
| `key` | `app`, `key` — one letter `a-z`, one digit, or `return`, `tab`, `escape`, `space`, `delete`, `up`, `down`, `left`, `right` — plus `modifiers?` (`command`, `shift`, `option`, `control`) and `id?` (focus this element first; without `id` the key lands wherever focus already is) | `{ok, diff}` — a real key event posted to the app's pid, so it reaches a background app on any Space. Letters exist for tool shortcuts: a design app's tools have no elements, and Figma's pen is `p` and nothing else |
| `type` | `app`, `text` (max 500 chars), `id?` (focus this element first) | `{ok, diff}` — the whole string as real unicode key events, posted to the pid so it reaches a background window. TEXT ENTRY, not shortcuts: `key` with modifiers is still how you send command+a. One call instead of one per character, because a design app's inspector wants four numbers per shape and `-19.6875` alone is nine keys |
| `scroll` | `app`, `id`, `dx?`, `dy?` (at least one non-zero; negative `dy` scrolls down) | `{ok, diff}` — real wheel events at the element's midpoint — unverified on a window on another Space |
| `menus` | `app`, `query?` | Without `query`: `{menus, count, hint}` — the top-level menu titles and how many commands the bar holds. With `query`: `{items, count}` — every command whose `Menu > Title` path contains it, as `View > Show/Hide UI  ⌘\` (disabled ones say so), at most 60. Read from the CLOSED menu bar: no menu opens, nothing is pressed |
| `menu` | `app`, `item` (a title, or `Menu > Title` when the title is in several menus), `keepFront?` | `{ok, diff, ran, shortcut?}` — runs one menu command. The app is activated first, because a closed item pressed in a background app returns success and does nothing. A title found in two menus is refused naming both; a disabled one is refused saying so; an unknown one gets the nearest names |
| `pointer` | `app`, `id` (the element the fractions are measured in), `path?` (list of `{x, y}` FRACTIONS 0-1, max 120 — without `hold` that is one CLICK per point, which is how an outline is traced with a pen tool; omitted means the element's centre), `clicks?` (1-3; 2 is a double click, a different event that some controls honour where one does not), `hold?`, `modifiers?` | `{ok, diff, at}` — a click at each point, or one press-drag-release with `hold`; `at` reports the screen points used. Posted to the HID tap at real coordinates, so it REFUSES a window that is parked or on another Space: a click there would land on whatever is at that spot |
| `screenshot` | `app`, `window?` (id from `windows`; default the focused window) | `{image, mime, width, height, window, onSpace, note?}` — JPEG (base64, `mime` says) of that one window, taken through ScreenCaptureKit wherever the window is, without raising anything; 1x; needs Screen Recording. Off-Space windows carry `note`: what the app only draws while visible (map tiles, video) may be blank |
| `raise` | `app`, `window?` | `{ok, diff}` — brings the app forward from any Space. Takes the user's screen: only when the user should see the app |
| `launch` | `app`, `timeout?`(15), plus the `tree` options | `{ok, alreadyRunning, tree, count, offscreen, hint?}` — opens the app (in the background when `crossSpace`) and waits until it is readable; on `timeout`, `ok` is still true if the app is running; the tree and `hint` say whether it is readable|
| `icon` | `app` | `{png}` — the app's icon, base64 PNG, 64px |
| `values` | `app`, `ids` (list of element ids, at most 40) | `{values:[{id, role, title, value}]}` — the current value of each id, one attribute read each and no tree walk; `role`/`title` are what the id last described; `value` is null when the element exposes none or the id is unknown. For checking the fields a batch just wrote, instead of reading the app again |
| `fields` | `app`, `limit?` (40) | `{fields:[{id, role, title, value}], truncated}` — the value-bearing controls (text fields, steppers, checkboxes, radio buttons, sliders, colour wells) in the latest snapshot — a pop-up or menu button is a menu trigger, not a field, and is left out, with their ids, in tree order; no AX traffic. For aiming the next action at an inspector without a `find` |

`setValue` accepts `verify: true`, which reads the value back and refuses when
it can PROVE the write did not land. It is OPT-IN, and that matters: measured
in Figma, an element the tree calls a `text field` (width, height, a hex box)
honours a value write and reports it immediately, while a `stepper`
(x-position, y-position, rotation) IGNORES it — the number appears in the box,
the value never changes, the tree keeps reporting the old one, and it commits
when focus leaves, which is how a 67 became 100100. Verifying by default
therefore refused writes that had landed on other elements and taught the
caller to distrust the bridge. For a stepper the working sequence is four
steps in one batch: `pointer` the field, `key a +command`, `type` the number,
`key return` — verified live. With `verify: true` it Two proofs, both measured in
Figma: the field is a number that differs beyond rounding (a width still
holding `120` given `180` came back `120180`, and seventeen coordinates were
computed on top of it), or the old text is still in front of what was written.
Everything else passes, because a field that reformats what it stored is
working: `160.3125` displayed as `160.31`, `100` as `100%`, an element with no
value at all. The refusal names the wanted and actual values and hands over the
select-all-then-type call. It throws BEFORE the snapshot, so the diff baseline
is untouched and the next read still shows what the bad write did. `verify:
false` skips the read.

Two actions ask the app before they post anything, and refuse on evidence
only. `pointer` asks what is under the FIRST point of its path
(`AXUIElementCopyElementAtPosition`): the anchor itself or something inside it
proceeds; a container of the anchor — in the tree, or a surface whose own box
encloses the anchor's box, which is what a canvas answers for every point —
proceeds, because it proves nothing either way; only an element with its own
separate box refuses with `action_failed` naming what IS there — an element's
reported bounds can lag what the app is drawing, and the click would land on the
wrong object. `type` without an `id` asks what holds keyboard focus: a text
field, text area, search field, combo box or stepper proceeds; anything else
refuses, because the characters would reach the app as keyboard shortcuts. Both
say that nothing was posted and what to do instead. Measured 2026-09-08, both
on the same run: a click aimed inside one element selected a different one, and
a coordinate typed after a click that had not taken focus changed a setting
instead — a dozen and six turns respectively to find out and repair.

Both refusals name the way through, because a refusal a caller cannot act on
is just a wall. The digit one says how to enter a number AND that an `id`
aims a deliberate shortcut at an element, which is the case it was measured
getting wrong: on 2026-09-09 a caller meant a digit as a zoom key, read the
refusal three times, and never found the escape hatch. And when an app
reports nothing under a point twice in a row, the second refusal stops
repeating itself and says the surface does not report what is on it, so no
choice of fraction will reach anything there — find the thing by name and act
on the id, or use the keyboard. The count is per app and is cleared by any
pointer that lands, so a one-off miss never escalates. Measured the same day:
three of these in ninety seconds against a panel that hit-tests nowhere, and
the caller answered the repeated sentence with two more clicks.

The menu bar is the app's commands by name. Measured 2026-09-09: told to hide
the app's panels before drawing, a caller pressed Tab — the shortcut for that
in some other design app — and the toolbar it meant to avoid ended its path at
point 43. The command it wanted was in the menu bar the whole time, with its
real key beside it: View > Show/Hide UI, ⌘\. Menus are native AppKit even in
an Electron app, so the closed bar enumerates completely — 420 items on that
app, in one pass — which is what `menus` returns, and `menu` runs one by name
instead of a guessed shortcut. One measured wrinkle shapes `menu`: pressing a
closed item while another app is frontmost returns success and changes
nothing (an Electron menu action goes to the focused window, and there is
none), so the app is activated first.

A click path is checked at EVERY point, not only its first, before anything is
posted, and checked again point by point as it is clicked. A drag is one
gesture from its first point, so only that point can land wrong; a click path
is a click at each point, and each one can. Measured 2026-09-09: a drawing
app raised a floating toolbar over the bottom of its surface the moment the
first pen point was placed — after the first-point check had passed — and the
trace's last dozen clicks pressed Bend and Cut instead of placing anchors. So
a later point on a control refuses the whole path up front ("Point 63 of 89
lands on button "Bend" … Nothing was clicked. Scroll or pan so the whole shape
is clear of it"); and a control that appears under the path while it is being
clicked stops the clicks in front of it, and the reply says "Clicked 62 of 89
points, then stopped … what was drawn is still open at point 62 … continue
from point 63". The check is one `AXUIElementCopyElementAtPosition` per point.

Within one click the move, press and release are 12ms apart; the 70ms
cadence the app needs is between points. Measured 2026-09-10: a 112-point trace
paced at 70ms after every event took 33s, 23s of it inside the clicks.

A click path is paced so the app never sees a double-click the caller did not
ask for. Two clicks within the double-click radius and interval are one
double-click to whoever counts them, and a pen tool ends its path on one.
Measured 2026-09-09: a 91-point trace had twelve consecutive points within six
screen points, one pair on the same pixel, posted ~200ms apart against a 500ms
interval; the outline came out as eleven open fragments and the caller
abandoned the tool. So with `clicks` 1 and no `hold`, a point within 8 screen
points of the previous click waits out the system double-click interval before
it is posted, and a point on the same pixel is not clicked twice at all — the
reply's `at` lists what was clicked, and a `note` says how many were skipped and
why. A caller that wants a double-click still asks for `clicks: 2`.

An open menu owns the pointer. While the tree shows one — a `menu bar item`
marked `[selected]` with its `menu item`s beneath it, or a context menu's items
— `pointer` refuses with `action_failed` naming the menu, because the first
click or drag would only dismiss it and reach nothing else. The decision is
made on a fresh snapshot, so a menu closed since the last read does not block.
And when an action's whole diff is menu roles — the bar item losing
`[selected]`, its items removed — the diff opens with a line saying the action
dismissed a menu and reached nothing else, so the lines below are not read as
the app reacting to the click. Measured 2026-09-08: a press opened a menu and
the next eight drags each returned the same handful of `menu bar item` lines;
ten minutes went on blaming the display.

Two rules for `key`, both about keys that destroy. A bare digit — one
character, no modifiers, no `id` — is text whatever the verb says: when
keyboard focus is not on an editable control it is refused with
`action_failed`, because a digit sent at a canvas is a shortcut, not a value
(measured twice on 2026-09-08: shapes came out at 28% and 40% opacity). Letters
stay free; one-letter tool shortcuts are the point of the verb. And `delete`
outside an editable control removes OBJECTS, so a `settle: false` delete is
watched anyway: the bridge snapshots just before it, settles after it, and
returns that step's own diff with the removed nodes named ("- removed: 859-880,
among them: application group "Unbiased, Design frame"; …") plus a `watched`
field saying why; the baseline is not moved, so the closing read still shows
the whole sequence. A standalone delete names its removals the same way.
Measured 2026-09-08: return, delete, return, delete in one unwatched batch
removed the frame the task lived in; the closing read said only "- removed:
859-880", the caller wrote "the frame is clean now", and six minutes went on
looking for it.

Every action also accepts `settle: false`, which returns `{ok, settled:false}`
the moment the app accepts it: no wait, no snapshot, and the diff baseline left
where it was. It is for the middle of a known sequence — five inspector fields
set on one shape — where only the last step's diff is read; the closing action
settles as usual and its diff then covers the whole run. Measured on a Figma
icon built out of inspector fields: 372 actions paid 253 seconds of settling, a
fifth of the task. It does not skip any refusal: an unlisted action, a missing
id and a repeat that changed nothing are declined exactly as before.

Every action accepts the `tree` options (`depth`, `maxElements`, `interactive`,
`web`; `geometry` is not one of them for actions) for the snapshot it takes
afterwards; use the same ones you read with, or the diff is full of `+`
structural lines and the wait ends early. `geometry` is ignored for action diffs
and for `launch`'s tree.

`app` is a name ("Brave Browser"), a name prefix ("Brave"), a bundle id, or a pid.
`keepFront` restores whatever app was in front before an action; off by
default because restoring after every action undid the one raise that made an
app readable, and the next read raised again.

## Element lines

    3     text field "Address and search bar" = youtube.com/ [focused] {press}

`id`, indentation by depth, role, `"title"`, `= value`, flags (`[focused]`
`[selected]` `[disabled]`), `{actions}`, and with `geometry:true` `@x,y wxh`.
Titles and values are clipped at 120 characters.

`windows.text` is one line per window, flags only when they apply:

    1 "YouTube - Brave" @0,0 1200x800 [focused] [minimized] [other Space]

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
