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
   at most 1.5s. An action that changes nothing pays the full 1.5s. A tree that
   has only *shrunk* since the action is treated as in transition (a result
   list that collapsed before its place card rendered) and waits up to 3.5s for
   what replaces it. The result carries `waitedMs`. The first action on an app
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

A window whose surface the window server has shrunk to a thumbnail (measured on Maps: 108x97 while the Accessibility API reported 1024x768) stops hit-testing its SwiftUI-hosted controls — list rows, card buttons, mode tabs accept `press` and do nothing — while AppKit controls (Close, the menu bar) and posted keys work, and a picture of it is blank. An action that changes nothing in that state carries a `hint` saying so and naming the paths that work. Raising the app restores the surface for the rest of the session.

`screenshot` photographs a window on another Space as well (measured: Maps' UI came back in 72ms with Brave still frontmost). What the app does not draw while hidden is black in the picture; controls and text are not.

## Methods

| method | params | result |
|---|---|---|
| `hello` | — | `{name, protocolVersion, trusted, crossSpace}` — works without Accessibility |
| `apps` | — | `{apps:[{pid,name,bundleId,frontmost}]}` — works without Accessibility |
| `windows` | `app` | `{windows:[{id,title,x,y,width,height,minimized,focused,onSpace}], text, offscreen, hint?}` — one line per window |
| `tree` | `app`, `depth?`(14), `maxElements?`(1500), `interactive?`, `web?` (Chromium page content, opt-in, sticky for that process), `geometry?`, `full?` | `{tree|diff, count, truncated, offscreen, hint?}` |
| `find` | `app`, `role?` (exact), `title?` (substring, also matches value), plus the `tree` options | `{matches:[lines], count, offscreen, hint?}` — a search, not a dump |
| `act` | `app`, `id`, `action` (`press`, `confirm` — commits a text field —, `raise`, `show menu`, `focus`, or any action shown in braces), `keepFront?` (default false) | `{ok, diff}` |
| `setValue` | `app`, `id`, `value`, `keepFront?` (default false) | `{ok, diff}` — focuses the element first; it does not commit — follow with `key return` for an omnibox |
| `key` | `app`, `key` (`return`, `tab`, `escape`, `space`, `delete`, `up`, `down`, `left`, `right`), `id?` (focus this element first; without `id` the key lands wherever focus already is) | `{ok, diff}` — a real key event posted to the app's pid |
| `scroll` | `app`, `id`, `dx?`, `dy?` (at least one non-zero; negative `dy` scrolls down) | `{ok, diff}` — real wheel events at the element's midpoint — unverified on a window on another Space |
| `screenshot` | `app`, `window?` (id from `windows`; default the focused window) | `{image, mime, width, height, window, onSpace, note?}` — JPEG (base64, `mime` says) of that one window, taken through ScreenCaptureKit wherever the window is, without raising anything; 1x; needs Screen Recording. Off-Space windows carry `note`: what the app only draws while visible (map tiles, video) may be blank |
| `raise` | `app`, `window?` | `{ok, diff}` — brings the app forward from any Space. Takes the user's screen: only when the user should see the app |
| `launch` | `app`, `timeout?`(15), plus the `tree` options | `{ok, alreadyRunning, tree, count, offscreen, hint?}` — opens the app (in the background when `crossSpace`) and waits until it is readable; on `timeout`, `ok` is still true if the app is running; the tree and `hint` say whether it is readable|
| `icon` | `app` | `{png}` — the app's icon, base64 PNG, 64px |

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
