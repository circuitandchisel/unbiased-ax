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
   at most 1.5s. An action that changes nothing pays the full 1.5s. The first
   action on an app never read has no baseline: it returns at once, and `diff`
   is the full tree.

## Spaces

`hello` reports `crossSpace`. When true, windows on another Space are in the
tree and take actions like any other; `windows` marks them `[other Space]` and
`offscreen` counts them. Nothing needs raising to be read. With it false,
`offscreen` is every layer-0 window the window server lists that is not on
screen — other Spaces, hidden and minimized alike — and it is inflated by system
windows that are not windows at all; treat it as a signal, not a count. When
false — the private path has not passed its self-check on this machine, or the
process is not yet trusted — only the current Space is readable, and reads carry
a `hint` saying whether to `raise`. The verdict is decided on the first trusted
call that finds an app to witness with — retried at most every 30s until then —
and can turn from false to true in a long-lived bridge; call `hello` again to
see it. Deciding it costs the first trusted call up to five seconds.

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
| `launch` | `app`, `timeout?`(15), plus the `tree` options except `geometry` | `{ok, alreadyRunning, tree, count, offscreen, hint?}` — opens the app (in the background when `crossSpace`) and waits until it is readable |
| `icon` | `app` | `{png}` — the app's icon, base64 PNG, 64px |

Every action accepts the `tree` options (`depth`, `maxElements`, `interactive`,
`web`) for the snapshot it takes afterwards; use the same ones you read with, or
the diff is full of `+` structural lines and the wait ends early. `geometry` is
ignored for action diffs and for `launch`'s tree.

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
