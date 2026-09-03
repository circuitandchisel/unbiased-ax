# unbiased-ax protocol (version 1)

Newline-delimited JSON over stdio. One request per line, one response per line,
in order. EOF on stdin is a clean shutdown. Nothing else is ever written to
stdout; diagnostics go to stderr.

    {"id":1,"method":"tree","params":{"app":"Brave","interactive":true}}
    {"id":1,"result":{"tree":"1 standard window \"…\" {raise}\n2   toolbar\n…","count":41,"truncated":false}}

Two rules the model must know:

1. **Ids are stable per app until the element disappears.** `act 17` two turns
   later hits the same element or is refused with `no_such_element` — never a
   different element.
2. **`tree` returns a diff after the first call** for an app, unless
   `"full":true`. `~` changed, `+` added, `- removed: 2-4, 9`. `(no changes)`
   when nothing moved.

## Methods

| method | params | result |
|---|---|---|
| `hello` | — | `{name, protocolVersion, trusted}` — works without Accessibility |
| `apps` | — | `{apps:[{pid,name,bundleId,frontmost}]}` — works without Accessibility |
| `windows` | `app` | `{windows:[…], text}` — one line per window: `1 "Title" @x,y wxh [focused]` |
| `tree` | `app`, `depth?`(14), `maxElements?`(1500), `interactive?`, `geometry?`, `full?` | `{tree|diff, count, truncated}` |
| `find` | `app`, `role?`, `title?` (substring, also matches value) | `{matches:[lines], count}` — a search, not a dump |
| `act` | `app`, `id`, `action` (`press`, `raise`, `show menu`, `focus`, or any action shown in braces) | `{ok, diff}` |
| `setValue` | `app`, `id`, `value` | `{ok, diff}` |
| `raise` | `app`, `window?` | `{ok, diff}` — brings the app forward from any Space |

`app` is a name ("Brave Browser"), a name prefix ("Brave"), a bundle id, or a pid.

## Element lines

    3     text field "Address and search bar" = youtube.com/ [focused] {press}

`id`, indentation by depth, role, `"title"`, `= value`, flags (`[focused]`
`[selected]` `[disabled]`), `{actions}`, and with `geometry:true` `@x,y wxh`.

## Errors

    {"id":1,"error":{"code":"not_trusted","message":"…"}}

| code | meaning |
|---|---|
| `bad_request` | the line was not a JSON object with a `method` |
| `bad_params` | a required param is missing; the message names it |
| `unknown_method` | the message lists the methods |
| `not_trusted` | Accessibility not granted to this process; the message says where |
| `no_such_app` | nothing running matches; call `apps` |
| `no_such_element` | the id is not in this app's last snapshot; call `tree` |
| `no_such_window` | call `windows` |
| `action_failed` | the app refused; supported actions are the ones in braces |
| `timeout` | the app did not answer within the messaging timeout |
