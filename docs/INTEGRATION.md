# Integrating unbiased-ax into unbiased-app

This is the follow-up plan for the *app* repo, not this one. It is written so
the first stage is a few lines, and each later stage stands on its own.

## 1. Discovery

`make bundle` produces `dist/unbiased-ax` and `dist/manifest.json` in the same
shape as the learning sidecar's `sidecar.json`, except `"runtime": "native"`.
`readSidecarManifest` in `src/main/learning.ts` currently refuses unknown
runtimes; accept `native` and treat `entry` as an executable rather than a
script for node. Resolve the directory the way `resolveSidecarDir` does
(override → packaged `Contents/Resources/ax` → sibling checkout), so a worktree
finds it too.

## 2. Process and permission

Spawn once, after the engine connects, and keep it running: the stable ids and
the diffs live in that process. The Accessibility grant belongs to whichever
bundle spawns it, so shipping inside `Unbiased.app` via `extraResources` means
the existing grant covers it, and the dev launcher's identity covers it in
development. If the grant ever proves fragile across re-signs, the alternative
is a dedicated helper `.app` with its own identity, which is what Codex does.

## 3. Two dynamic tools first

Alongside the existing `computer_*` tools, declared per thread in
`threadDynamicTools()`:

- `computer_app_state(app, interactive?, web?, full?, depth?)` → the tree, or
  the diff since the last call. This is the tool the model reaches for *before*
  a screenshot: it answers "where is Brave, which tab is selected" as text,
  across Spaces.
- `computer_act(app, id, action | value)` → performs `act` or `setValue` and
  returns the diff. Route through `requestLocalApproval` exactly as the other
  computer tools do; the approval card shows the element line, so the user sees
  *what* will be pressed, not a coordinate.
- `computer_raise(app)` → brings an app forward from any Space.

Screenshots stay as the fallback for content the tree does not expose — page
content in a browser without `web:true`, canvases, games.

`dynamicToolSource` should classify these as `"computer"` so they render as
computer steps, not shell commands.

## 4. Then code mode

The engine already ships Codex's code mode (`features.code_mode`,
`code_mode_host`, MCP `tool_mode = "code_mode_only"`). Register the bridge as an
MCP server with `tool_mode = "code_mode_only"` and the model gets a persistent
JavaScript session: `state = ax.tree("Brave"); ax.setValue(3, url); ax.act(3,
"press"); ax.tree("Brave")` in **one** call, trimming output itself. That is
the seven-call profile. It needs the `codex-code-mode-host` binary; confirm its
provenance in the open-source codex repo before committing to this stage.

## 5. Approvals

Today every primitive is a human click. With code mode, one approval per call
is the natural unit. Codex goes further with policy tiers the model applies
itself. That is a product decision; do not change it in stage 3.
